// Incremental SHA-256: a large recording never needs to fit in browser memory.
const primes=[];for(let n=2;primes.length<64;n++){if(!primes.some(p=>p*p<=n&&n%p===0))primes.push(n)}
const K=primes.map(p=>(Math.cbrt(p)%1*0x100000000)>>>0);
const initial=primes.slice(0,8).map(p=>(Math.sqrt(p)%1*0x100000000)>>>0);
const rotr=(x,n)=>(x>>>n)|(x<<(32-n));
export class SHA256{
 constructor(){this.h=initial.slice();this.buffer=new Uint8Array(64);this.used=0;this.length=0;this.finished=false;this.w=new Uint32Array(64)}
 block(b){const w=this.w;for(let i=0;i<16;i++)w[i]=(b[i*4]<<24)|(b[i*4+1]<<16)|(b[i*4+2]<<8)|b[i*4+3];for(let i=16;i<64;i++){let x=w[i-15],y=w[i-2];w[i]=(w[i-16]+(rotr(x,7)^rotr(x,18)^(x>>>3))+w[i-7]+(rotr(y,17)^rotr(y,19)^(y>>>10)))>>>0}let[a,b1,c,d,e,f,g,h]=this.h;for(let i=0;i<64;i++){let t1=(h+(rotr(e,6)^rotr(e,11)^rotr(e,25))+((e&f)^(~e&g))+K[i]+w[i])>>>0;let t2=((rotr(a,2)^rotr(a,13)^rotr(a,22))+((a&b1)^(a&c)^(b1&c)))>>>0;h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b1;b1=a;a=(t1+t2)>>>0}let v=[a,b1,c,d,e,f,g,h];for(let i=0;i<8;i++)this.h[i]=(this.h[i]+v[i])>>>0}
 update(bytes){if(this.finished)throw Error('hash already finalized');this.length+=bytes.length;let p=0;while(p<bytes.length){const n=Math.min(64-this.used,bytes.length-p);this.buffer.set(bytes.subarray(p,p+n),this.used);this.used+=n;p+=n;if(this.used===64){this.block(this.buffer);this.used=0}}return this}
 hex(){if(this.finished)throw Error('hash already finalized');const bits=BigInt(this.length)*8n;const padding=new Uint8Array((this.used<56?64:128)-this.used);padding[0]=128;for(let i=0;i<8;i++)padding[padding.length-1-i]=Number((bits>>BigInt(i*8))&255n);this.update(padding);this.finished=true;return this.h.map(v=>v.toString(16).padStart(8,'0')).join('')}
}
