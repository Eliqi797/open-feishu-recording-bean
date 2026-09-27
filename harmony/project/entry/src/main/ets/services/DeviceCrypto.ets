import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { concat, counter } from './D3200Protocol';

const P256_SPKI = new Uint8Array([48,89,48,19,6,7,42,134,72,206,61,2,1,6,8,42,134,72,206,61,3,1,7,3,66,0]);
function unhex(value:string):Uint8Array {
  const out=new Uint8Array(value.length/2);
  for(let i=0;i<out.length;i++)out[i]=parseInt(value.slice(i*2,i*2+2),16);
  return out;
}
function equalBytes(a:Uint8Array,b:Uint8Array):boolean {
  let diff=a.length^b.length;
  for(let i=0;i<a.length;i++)diff|=a[i]^b[i];
  return diff===0;
}

export async function sha(bytes: Uint8Array): Promise<Uint8Array> {
  const hash = cryptoFramework.createMd('SHA256'); await hash.update({data: bytes}); return (await hash.digest()).data;
}
export function hex(bytes: Uint8Array): string { return Array.from(bytes).map((v: number) => v.toString(16).padStart(2, '0')).join(''); }
async function hmac(key: Uint8Array, value: Uint8Array): Promise<Uint8Array> {
  const material = key.length > 64 ? await sha(key) : key;
  const inner = new Uint8Array(64), outer = new Uint8Array(64);
  for (let i = 0; i < 64; i++) { const b = i < material.length ? material[i] : 0; inner[i] = b ^ 54; outer[i] = b ^ 92; }
  return sha(concat(outer, await sha(concat(inner, value))));
}
async function aes(key: Uint8Array, iv: Uint8Array, bytes: Uint8Array): Promise<Uint8Array> {
  const cipher = cryptoFramework.createCipher('AES256|CTR|NoPadding');
  const secret = await cryptoFramework.createSymKeyGenerator('AES256').convertKey({data: key});
  const spec: cryptoFramework.IvParamsSpec = {algName: 'IvParamsSpec', iv: {data: iv}};
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, secret, spec);
  return (await cipher.doFinal({data: bytes})).data;
}
export class DeviceCrypto {
  diagnostics:string='ECDH 自检尚未运行';
  private selfTestPassed:boolean=false;
  private pair: cryptoFramework.KeyPair | undefined = undefined;
  private session: Uint8Array = new Uint8Array(0);
  private fileKey: Uint8Array = new Uint8Array(0);
  private nonce: Uint8Array = new Uint8Array(0);
  private async selfTest():Promise<void> {
    if(this.selfTestPassed)return;
    // Public deterministic test vector: scalar 1 x public point 2G = 2G.x.
    // This fixture is NEVER used for a device connection; production keys stay random.
    const fixture=unhex('308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b02010104200000000000000000000000000000000000000000000000000000000000000001a144034200046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5');
    const point=unhex('047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1');
    const generator=cryptoFramework.createAsyKeyGenerator('ECC256');
    const own=await generator.convertKey(null,{data:fixture});
    const peer=await generator.convertKey({data:concat(P256_SPKI,point)},null);
    const computed=(await cryptoFramework.createKeyAgreement('ECC256').generateSecret(own.priKey,peer.pubKey)).data;
    const valid=equalBytes(computed,point.slice(1,33));computed.fill(0);fixture.fill(0);
    if(!valid){this.diagnostics='原生 ECDH 固定向量校验失败';throw new Error('D3200_NATIVE_ECDH_SELF_TEST_FAILED');}
    this.selfTestPassed=true;
  }
  async publicKey(): Promise<Uint8Array> {
    this.clear();await this.selfTest();this.diagnostics='ECDH 固定向量通过；等待设备回应';
    this.pair = await cryptoFramework.createAsyKeyGenerator('ECC256').generateKeyPair();
    const der = this.pair.pubKey.getEncoded().data;
    if(der.length!==P256_SPKI.length+65||!equalBytes(der.slice(0,P256_SPKI.length),P256_SPKI))throw new Error('D3200_PUBLIC_KEY_CURVE_MISMATCH');
    const point = der.slice(-65);
    if (point.length !== 65 || point[0] !== 4) throw new Error('D3200_PUBLIC_KEY_ENCODING');
    return point;
  }
  async handshake(payload: Uint8Array): Promise<void> {
    if (!this.pair || payload.length < 97 || payload[0] !== 4) throw new Error('D3200_HANDSHAKE_INVALID');
    // SubjectPublicKeyInfo for id-ecPublicKey / prime256v1 + uncompressed point.
    const peer = await cryptoFramework.createAsyKeyGenerator('ECC256').convertKey({data: concat(P256_SPKI, payload.slice(0, 65))}, null);
    const secret = (await cryptoFramework.createKeyAgreement('ECC256').generateSecret(this.pair.priKey, peer.pubKey)).data;
    try {
      const check=payload.slice(65,97);
      const derived=await hmac(await hmac(new Uint8Array([1,2,3]), secret), new Uint8Array([1,2,3,1]));
      try {
        // Only lengths and comparisons enter diagnostics, never secret bytes/hashes.
        this.diagnostics=`ECDH 自检通过；回应 ${payload.length} 字节；计算结果 ${secret.length} 字节；校验字段全零=${check.every((v:number)=>v===0)}；原值匹配=${equalBytes(secret,check)}；逆序匹配=${equalBytes(secret.slice().reverse(),check)}；SHA256匹配=${equalBytes(await sha(secret),check)}；HKDF匹配=${equalBytes(derived,check)}`;
        if(secret.length!==32||!equalBytes(secret,check))throw new Error('D3200_SHARED_SECRET_MISMATCH');
        this.session=derived.slice();
      } finally {derived.fill(0);}
    } finally {secret.fill(0);}
  }
  async file(payload: Uint8Array): Promise<void> {
    if (payload.length < 87 || this.session.length !== 32) throw new Error('D3200_FILE_KEY_MISSING');
    if (payload[86] !== 0 && payload[86] !== 255) throw new Error('D3200_FILE_UNAVAILABLE');
    const plain = await aes(this.session, payload.slice(70, 86), payload.slice(24, 70));
    // The documented marker is 14 bytes (including its final character 0).
    const magic = 'soundcored3200';
    if (plain.length !== magic.length + 32) throw new Error('D3200_FILE_KEY_INVALID');
    for (let i = 0; i < magic.length; i++) if (plain[i] !== magic.charCodeAt(i)) throw new Error('D3200_FILE_KEY_INVALID');
    this.fileKey.fill(0); this.fileKey = plain.slice(magic.length); plain.fill(0); this.nonce = payload.slice(8,24);
  }
  async decrypt(sequence: number, data: Uint8Array): Promise<Uint8Array> {
    if (this.fileKey.length !== 32 || data.length !== 160) throw new Error('D3200_FILE_KEY_MISSING');
    return aes(this.fileKey, counter(this.nonce, sequence), data);
  }
  clear(): void {this.session.fill(0);this.fileKey.fill(0);this.nonce.fill(0);this.pair=undefined;}
}
