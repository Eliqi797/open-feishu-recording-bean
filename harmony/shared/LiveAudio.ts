import { concat, oggPage, opusHeaders } from './D3200Protocol.ts';
// Independently decodable, bounded preview windows; complete audio keeps its own continuous pages.
export function liveWindow(packets:Uint8Array[]):Uint8Array {
  if(packets.length<1||packets.length>1000||packets.some((p:Uint8Array)=>p.length!==160))throw new Error('LIVE_WINDOW_INVALID');
  const parts:Uint8Array[]=[opusHeaders(0)];let size=parts[0].length;
  for(let i=0;i<packets.length;i++){const page=oggPage(packets[i],i+2,(i+1)*960,i===packets.length-1?4:0);parts.push(page);size+=page.length;}
  const out=new Uint8Array(size);let at=0;for(const part of parts){out.set(part,at);at+=part.length;}return out;
}
