export interface TransferView {
  active:boolean;phase:string;fileTitle:string;index:number;count:number;
  downloaded:number;uploaded:number;done:number;total:number;speed:number;message:string;
}
export function emptyTransfer():TransferView{return{active:false,phase:'idle',fileTitle:'',index:0,count:0,downloaded:0,uploaded:0,done:0,total:0,speed:0,message:''};}
export function transferBytes(bytes:number):string{
  const safe=Math.max(0,Number.isFinite(bytes)?bytes:0);
  if(safe>=1024*1024)return (safe/1048576).toFixed(1)+' MB';
  if(safe>=1024)return (safe/1024).toFixed(1)+' KB';
  return Math.floor(safe)+' B';
}
interface SpeedSample {time:number;bytes:number;}
export class TransferSpeed {
  private samples:SpeedSample[]=[];
  private latest:number=0;
  private changed:number=0;
  reset(now:number,bytes:number=0):void{this.samples=[{time:now,bytes}];this.latest=bytes;this.changed=now;}
  add(now:number,bytes:number):void{
    if(!Number.isFinite(bytes)||bytes<0)return;
    if(!this.samples.length||bytes<this.latest){this.reset(now,bytes);return;}
    if(bytes>this.latest){this.latest=bytes;this.changed=now;if(now-this.samples[this.samples.length-1].time>=100)this.samples.push({time:now,bytes});}
    while(this.samples.length>2&&this.samples[1].time<now-3000)this.samples.shift();
  }
  value(now:number):number{
    if(!this.samples.length||now-this.changed>=2500)return 0;
    const first=this.samples[0];return now>first.time?Math.max(0,(this.latest-first.bytes)*1000/(now-first.time)):0;
  }
}
