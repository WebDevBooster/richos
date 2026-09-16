import fs from 'node:fs';
const original=fs.readFileSync;
fs.readFileSync=function(file,...args){if(file===0)process.stderr.write('AUDIT_STDIN_READY\n');return original.call(this,file,...args);};
