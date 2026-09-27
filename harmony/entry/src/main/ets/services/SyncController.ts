// Platform-neutral sync contract. Integrate into a DevEco project after SDK validation.
export interface RecordingRef { deviceId: string; sourceId: string; title: string; }
export interface LocalAudio { path: string; size: number; sha256: string; mime: string; }
export interface UploadedChunk { idx: number; sha256: string; size: number; }
export interface UploadSession { upload_id: string; recording_id: string; size: number; sha256: string; chunk_size: number; stored: boolean; chunks: UploadedChunk[]; }
export interface Receipt { recording_id: string; stored: boolean; verified: boolean; sha256: string; size: number; }
export interface Chunk { bytes: Uint8Array; sha256: string; }
export interface SyncJournal { source: RecordingRef; phase: string; uploadId: string; recordingId: string; error: string; }
export interface DevicePort { downloadAndDecrypt(source: RecordingRef): Promise<LocalAudio>; restoreInternet(): Promise<void>; }
export interface CachePort {
  findVerified(source: RecordingRef): Promise<LocalAudio | undefined>;
  retain(source: RecordingRef, audio: LocalAudio): Promise<void>;
  chunk(audio: LocalAudio, offset: number, length: number): Promise<Chunk>;
  remove(audio: LocalAudio, source?:RecordingRef): Promise<void>;
  persist(journal: SyncJournal): Promise<void>;
}
export interface CloudPort {
  begin(source: RecordingRef, audio: LocalAudio): Promise<UploadSession>;
  put(uploadId: string, index: number, chunk: Chunk, progress?:(sent:number)=>void): Promise<void>;
  complete(uploadId: string): Promise<Receipt>;
}
export class SyncController {
  private busy: boolean = false;
  private cancelled: boolean = false;
  private device: DevicePort;
  private cache: CachePort;
  private cloud: CloudPort | undefined;
  private update: (phase: string, completed: number, total: number) => void;
  constructor(device: DevicePort, cache: CachePort, cloud: CloudPort | undefined,
              update: (phase: string, completed: number, total: number) => void) {
    this.device = device; this.cache = cache; this.cloud = cloud; this.update = update;
  }
  cancel(): void { this.cancelled = true; }
  private checkpoint(): void { if (this.cancelled) throw new Error('SYNC_CANCELLED'); }
  private async retryCloud<T>(action:()=>Promise<T>,phase:string,done:number,total:number):Promise<T>{
    // Upload session, chunk and completion endpoints are idempotent. Never retry auth,
    // certificate, checksum, or arbitrary application failures.
    for(let attempt=0;;attempt++){
      this.checkpoint();this.update(phase,done,total);
      try{return await action();}catch(error){
        const code=(error as Error).message;
        if(attempt>=2||!/^CLOUD_NETWORK_23000(06|07|28|52|55|56)$/.test(code))throw error;
        this.checkpoint();this.update('retrying',done,total);
        await new Promise<void>((resolve)=>{setTimeout(resolve,(attempt+1)*1000);});
      }
    }
  }
  async downloadOnly(source: RecordingRef, restoreNetwork:boolean=true): Promise<LocalAudio> {
    if (this.busy) throw new Error('SYNC_ALREADY_RUNNING');
    this.busy = true; this.cancelled = false;
    const journal: SyncJournal = {source, phase: 'downloading', uploadId: '', recordingId: '', error: ''};
    try {
      await this.cache.persist(journal);
      let audio = await this.cache.findVerified(source);
      if (!audio) {
        this.checkpoint();
        this.update('downloading', 0, 0);
        audio = await this.device.downloadAndDecrypt(source);
        await this.cache.retain(source, audio);
      }
      this.checkpoint();
      if(restoreNetwork){journal.phase = 'restoring_network'; await this.cache.persist(journal);
      this.update('restoring_network',0,0);await this.device.restoreInternet();}
      this.checkpoint();
      journal.phase = 'cached'; await this.cache.persist(journal);
      this.update('cached', audio.size, audio.size);
      return audio;
    } catch (error) {
      journal.phase = 'interrupted'; journal.error = 'LOCAL_DOWNLOAD_FAILED_CACHE_RETAINED';
      await this.cache.persist(journal);
      throw error;
    } finally { this.busy = false; }
  }
  async sync(source: RecordingRef, cachedOnly:boolean=false): Promise<Receipt> {
    if (this.busy) throw new Error('SYNC_ALREADY_RUNNING');
    if (!this.cloud) throw new Error('CLOUD_NOT_CONFIGURED');
    this.busy = true; this.cancelled = false;
    const journal: SyncJournal = { source, phase: 'starting', uploadId: '', recordingId: '', error: '' };
    try {
      await this.cache.persist(journal);
      let audio = await this.cache.findVerified(source);
      if (!audio) {
        if(cachedOnly)throw new Error('CACHED_AUDIO_REQUIRED');
        journal.phase = 'downloading'; await this.cache.persist(journal);
        this.update('downloading', 0, 0);
        audio = await this.device.downloadAndDecrypt(source);
        await this.cache.retain(source, audio);
      }
      this.checkpoint();
      if(!cachedOnly){journal.phase = 'restoring_network'; await this.cache.persist(journal);
      this.update('restoring_network',0,0);await this.device.restoreInternet();}
      this.checkpoint();
      const cloud=this.cloud;const local=audio;
      const session = await this.retryCloud(()=>cloud.begin(source,local),'uploading',0,audio.size);
      if (session.sha256 !== audio.sha256 || session.size !== audio.size || session.chunk_size <= 0) throw new Error('UPLOAD_SESSION_MISMATCH');
      journal.uploadId = session.upload_id; journal.recordingId = session.recording_id;
      journal.phase = 'uploading'; await this.cache.persist(journal);this.update('uploading',0,audio.size);
      if (!session.stored) {
        for (let offset = 0, index = 0; offset < audio.size; offset += session.chunk_size, index++) {
          this.checkpoint();
          const chunk = await this.cache.chunk(audio, offset, Math.min(session.chunk_size, audio.size - offset));
          const existing = session.chunks.find(c => c.idx === index);
          if (!existing || existing.sha256 !== chunk.sha256){
            const total=audio.size;await this.retryCloud(()=>cloud.put(session.upload_id, index, chunk,(sent:number)=>{this.update('uploading',Math.min(total,offset+Math.max(0,Math.min(sent,chunk.bytes.length))),total);}),'uploading',offset,total);
            this.update('uploading', Math.min(audio.size, offset + session.chunk_size), audio.size);
          }else this.update('resuming',Math.min(audio.size,offset+session.chunk_size),audio.size);
        }
      }
      this.checkpoint();
      journal.phase = 'verifying'; await this.cache.persist(journal);this.update('verifying',audio.size,audio.size);
      const receipt = await this.retryCloud(()=>cloud.complete(session.upload_id),'verifying',audio.size,audio.size);
      if (!receipt.verified || !receipt.stored || receipt.recording_id !== session.recording_id || receipt.sha256 !== audio.sha256 || receipt.size !== audio.size) throw new Error('CLOUD_RECEIPT_MISMATCH');
      journal.phase = 'cleanup_pending'; await this.cache.persist(journal);
      await this.cache.remove(audio,source);
      journal.phase = 'completed'; await this.cache.persist(journal);
      this.update('completed', audio.size, audio.size);
      return receipt;
    } catch (error) {
      // Do not persist arbitrary transport errors: they may contain signed URLs or credentials.
      journal.error = 'SYNC_FAILED_RETRY_WITH_LOCAL_CACHE';
      if (journal.phase !== 'cleanup_pending') journal.phase = 'interrupted';
      await this.cache.persist(journal);
      throw error;
    } finally { this.busy = false; }
  }
}
