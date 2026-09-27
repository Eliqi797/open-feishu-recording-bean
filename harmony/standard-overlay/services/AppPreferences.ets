import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { writeFile } from './NativePorts';
export interface Preferences { origin:string; theme:string; wifi:boolean; keepAwake?:boolean; liveWindowSeconds?:number; autoUpload?:boolean; }
export class AppPreferences {
  private path:string;
  constructor(root:string){this.path=root+'/app-preferences.json';}
  read():Preferences {if(!fs.accessSync(this.path))return {origin:'',theme:'system',wifi:true};return JSON.parse(fs.readTextSync(this.path)) as Preferences;}
  private query(origin:string):asset.AssetMap {const map:asset.AssetMap=new Map();map.set(asset.Tag.ALIAS,new util.TextEncoder().encodeInto('recordingbean:'+origin));return map;}
  token(origin:string):string {
    if(!origin)return '';
    const query=this.query(origin);query.set(asset.Tag.RETURN_TYPE,asset.ReturnType.ALL);
    try{const rows=asset.querySync(query);return rows.length?new util.TextDecoder().decodeWithStream(rows[0].get(asset.Tag.SECRET) as Uint8Array):'';}
    catch(e){if((e as BusinessError).code===asset.ErrorCode.NOT_FOUND)return '';throw new Error('SECURE_STORAGE_READ_FAILED');}
  }
  save(prefs:Preferences,token:string):void {
    if(prefs.autoUpload===undefined)prefs.autoUpload=this.read().autoUpload!==false;
    if(prefs.liveWindowSeconds===undefined)prefs.liveWindowSeconds=this.read().liveWindowSeconds||5;
    if(prefs.keepAwake===undefined)prefs.keepAwake=this.read().keepAwake||false;
    if(prefs.origin&&token){
      const query=this.query(prefs.origin);const value:asset.AssetMap=new Map();value.set(asset.Tag.SECRET,new util.TextEncoder().encodeInto(token));
      try{asset.updateSync(query,value);}catch(e){if((e as BusinessError).code!==asset.ErrorCode.NOT_FOUND)throw new Error('SECURE_STORAGE_WRITE_FAILED');query.set(asset.Tag.SECRET,new util.TextEncoder().encodeInto(token));query.set(asset.Tag.ACCESSIBILITY,asset.Accessibility.DEVICE_FIRST_UNLOCKED);asset.addSync(query);}
    }
    writeFile(this.path,JSON.stringify(prefs));
  }
}
