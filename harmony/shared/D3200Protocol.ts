// Independently implemented from documented wire fields. See docs/REFERENCES.md.
// Only the read/transfer command subset is exposed; no bind, erase, reset or OTA.
export interface Frame { type: number; command: number; status: number; payload: Uint8Array; }
export interface DeviceFile { id: number; transferBytes: number; }
export interface DeviceInfoStatus {battery:number|null;charging:boolean|null;caseBattery:number|null;caseCharging:boolean|null;recording:number;}
// Documented bucket encoding; invalid and missing bytes must not appear as 0%.
export function batteryPercent(value:number|undefined):number|null {
  if(value===undefined||!Number.isInteger(value)||value<0||value>100)return null;
  return value<=9?(value+1)*10:value;
}
// Device-info payload: 3 status bytes + 5 firmware bytes, then 16 ASCII SN bytes.
// Reject missing/padding identifiers instead of falling back to a rotating BLE address.
export function deviceSerial(payload:Uint8Array):string {
  if(payload.length<24)throw new Error('D3200_STABLE_ID_UNAVAILABLE');
  let value='';for(let i=8;i<24;i++)value+=String.fromCharCode(payload[i]);
  value=value.replace(/[\x00 ]+$/,'').toLowerCase();
  if(!/^[a-z0-9]{8,16}$/.test(value)||/^(.)\1+$/.test(value)||['unknown','undefined','default','12345678','1234567890123456'].includes(value))throw new Error('D3200_STABLE_ID_UNAVAILABLE');
  return value;
}
export function deviceInfoStatus(payload:Uint8Array):DeviceInfoStatus {
  return {battery:batteryPercent(payload.length>1?payload[1]:undefined),charging:payload.length>2&&(payload[2]===0||payload[2]===1)?payload[2]===1:null,
    caseBattery:batteryPercent(payload.length>38?payload[38]:undefined),caseCharging:payload.length>32&&(payload[32]===0||payload[32]===1)?payload[32]===1:null,recording:recordingState(payload)};
}
// Device-info payload recording byte after fixed device/case fields and five settings.
// Unknown/truncated variants remain unknown, never inferred as idle.
export function recordingState(payload:Uint8Array):number {
  return payload.length>=51&&(payload[50]===0||payload[50]===1)?payload[50]:-1;
}
export function offlineTransferSize(value:number):number {
  if(value===0xffffffff)throw new Error('D3200_RECORDING_NOT_FINALIZED');
  if(!Number.isInteger(value)||value<=0||value>=0xffffffff)throw new Error('D3200_FILE_SIZE_INVALID');
  return value;
}
export function u32(data: Uint8Array, at: number): number {
  if (at < 0 || at + 4 > data.length) throw new Error('D3200_TRUNCATED_FIELD');
  return new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(at, true);
}
export function le(value: number, length: number = 4): Uint8Array {
  const b = new Uint8Array(length);
  for (let i = 0; i < length; i++) b[i] = (value >>> (i * 8)) & 255;
  return b;
}
export function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length); out.set(a); out.set(b, a.length); return out;
}
export function command(type: number, id: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  const allowed = ['1:1', '46:1', '26:14', '26:7', '26:5', '26:2', '26:15', '26:17'];
  if (!allowed.includes(`${type}:${id}`) || payload.length > 1024) throw new Error('D3200_COMMAND_NOT_ALLOWED');
  const b = new Uint8Array(payload.length + 10); b.set([8, 238, 0, 0, 0, type, id]);
  b.set(le(b.length, 2), 7); b.set(payload, 9);
  for (let i = 0; i < b.length - 1; i++) b[b.length - 1] = (b[b.length - 1] + b[i]) & 255;
  return b;
}
export class FrameDecoder {
  private buffer: Uint8Array = new Uint8Array(0);
  push(bytes: Uint8Array): Frame[] {
    if (this.buffer.length + bytes.length > 131072) throw new Error('D3200_RX_OVERFLOW');
    this.buffer = concat(this.buffer, bytes); const out: Frame[] = [];
    while (this.buffer.length >= 10) {
      if (this.buffer[0] !== 9 || this.buffer[1] !== 255 || this.buffer[2] !== 0 || this.buffer[3] !== 0) {
        this.buffer = this.buffer.slice(1); continue;
      }
      const size = this.buffer[7] + this.buffer[8] * 256;
      if (size < 10 || size > 65535) throw new Error('D3200_INVALID_FRAME_SIZE');
      if (this.buffer.length < size) break;
      const b = this.buffer.slice(0, size); this.buffer = this.buffer.slice(size);
      let sum = 0; for (let i = 0; i < size - 1; i++) sum = (sum + b[i]) & 255;
      if (sum !== b[size - 1]) throw new Error('D3200_CHECKSUM_MISMATCH');
      out.push({type: b[5], command: b[6], status: b[4], payload: b.slice(9, -1)});
    }
    return out;
  }
}
export function fileList(payload: Uint8Array): DeviceFile[] {
  if (payload.length < 2) throw new Error('D3200_INVALID_LIST');
  const count = payload[0] + payload[1] * 256;
  if (count > 4096 || payload.length < 2 + count * 8) throw new Error('D3200_TRUNCATED_LIST');
  const result: DeviceFile[] = [];
  for (let i = 0; i < count; i++) result.push({id: u32(payload, 2 + i * 8), transferBytes: u32(payload, 6 + i * 8)});
  return result;
}
export function counter(nonce: Uint8Array, sequence: number): Uint8Array {
  if (nonce.length !== 16 || !Number.isInteger(sequence) || sequence < 0 || sequence > 429496729) throw new Error('D3200_COUNTER_INVALID');
  const iv = nonce.slice(); new DataView(iv.buffer).setUint32(12, sequence * 10, false); return iv;
}
export interface AudioSlice { sequence: number; encrypted: Uint8Array; }
export function slices(payload: Uint8Array): AudioSlice[] {
  if (payload.length === 0 || payload.length % 166 !== 0) throw new Error('D3200_SLICE_LAYOUT_UNVERIFIED');
  const out: AudioSlice[] = [];
  for (let i = 0; i < payload.length; i += 166) out.push({sequence: u32(payload, i), encrypted: payload.slice(i + 5, i + 165)});
  return out;
}
// Standard Ogg page encoding. A single bounded packet per page avoids whole-file buffering.
export function oggPage(packet: Uint8Array, seq: number, granule: number, flags: number): Uint8Array {
  const segments = Math.floor(packet.length / 255) + 1;
  if (segments > 255) throw new Error('OGG_PACKET_TOO_LARGE');
  const out = new Uint8Array(27 + segments + packet.length);
  out.set([79, 103, 103, 83, 0, flags]);
  const view = new DataView(out.buffer);
  view.setUint32(6, granule >>> 0, true); view.setUint32(10, Math.floor(granule / 4294967296), true);
  view.setUint32(14, 0x4245414e, true); view.setUint32(18, seq, true); out[26] = segments;
  for (let i = 0; i < segments; i++) out[27 + i] = Math.min(255, packet.length - 255 * i);
  out.set(packet, 27 + segments);
  let crc = 0;
  for (let i = 0; i < out.length; i++) {crc ^= out[i] << 24; for (let bit = 0; bit < 8; bit++) crc = (crc & 0x80000000) ? (crc << 1) ^ 0x04c11db7 : crc << 1;}
  view.setUint32(22, crc >>> 0, true); return out;
}
export function opusHeaders(preSkip:number=312): Uint8Array {
  const head = new Uint8Array([79,112,117,115,72,101,97,100,1,2,56,1,128,62,0,0,0,0,0]);
  head[10]=preSkip&255;head[11]=(preSkip>>>8)&255;
  const tags = new Uint8Array([79,112,117,115,84,97,103,115,4,0,0,0,66,101,97,110,0,0,0,0]);
  return concat(oggPage(head, 0, 0, 2), oggPage(tags, 1, 0, 0));
}
