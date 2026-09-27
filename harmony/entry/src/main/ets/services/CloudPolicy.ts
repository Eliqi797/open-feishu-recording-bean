export function cloudOriginAllowed(origin:string,debug:boolean):boolean {
  return /^https:\/\/[a-zA-Z0-9.-]+(:[0-9]+)?$/.test(origin)||(debug&&origin==='usb://local');
}
