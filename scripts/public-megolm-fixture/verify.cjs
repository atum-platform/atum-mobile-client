const fs = require('fs');
const path = require('path');
const Olm = require('@matrix-org/olm');
Olm.init().then(() => {
  for (const name of ['baseline.patch', 'operation.patch']) {
    const source = fs.readFileSync(path.join(__dirname, '../../sdk/background-backup', name), 'utf8');
    const key = /"session_key": "([^"]+)"/.exec(source)[1];
    const id = /"session_id": "([^"]+)"/.exec(source)[1];
    const session = new Olm.InboundGroupSession();
    try { session.import_session(key); if (session.session_id() !== id) throw Error('session id mismatch'); }
    finally { session.free(); }
  }
  console.log('PASS: both public Megolm vectors import and match their session IDs');
});
