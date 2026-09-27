export function background(dark:boolean):string{return dark?'#101719':'#F4F7F7';}
export function surface(dark:boolean):string{return dark?'#1B272A':'#FFFFFF';}
export function ink(dark:boolean):string{return dark?'#EDF5F4':'#162C30';}
export function muted(dark:boolean):string{return dark?'#AABDBF':'#536C70';}
export function accent(dark:boolean):string{return dark?'#65DBC9':'#077568';}
export function line(dark:boolean):string{return dark?'#304246':'#DFE8E8';}

export function inset(dark:boolean):string{return dark?'#243639':'#EAF2F1';}
export function attention(dark:boolean):string{return dark?'#FFBC89':'#9B430D';}

export function recordingDate(seconds:number):string {if(!Number.isFinite(seconds)||seconds<946684800||seconds>4102444800)return '未知';const date=new Date(seconds*1000);const pad=(v:number):string=>String(v).padStart(2,'0');return date.getFullYear()+'-'+pad(date.getMonth()+1)+'-'+pad(date.getDate())+' '+pad(date.getHours())+':'+pad(date.getMinutes());}
