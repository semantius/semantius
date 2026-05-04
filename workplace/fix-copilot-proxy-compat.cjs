/**
 * GoProxy MITM compatibility fix for wrangler deployments.
 *
 * Root cause: The GoProxy MITM proxy case-sensitively requires "Content-Length"
 * (Title-Case) in HTTP/1.1 headers. undici (used by wrangler) sends all headers
 * in lowercase ("content-length"), which is valid per the HTTP/1.1 spec but
 * causes GoProxy to reject POST requests with a 400 Bad Request before
 * forwarding them to Cloudflare.
 *
 * Fix: Intercept TLS socket writes and capitalise the content-length header
 * in the HTTP header section (before \r\n\r\n) so the proxy can parse it.
 *
 * This is loaded via NODE_OPTIONS=--require in deploy-wrangler.sh and has no
 * effect outside of the deployment context.
 */
'use strict';

const tls = require('tls');
const origConnect = tls.connect;

tls.connect = function (options, ...rest) {
  const socket = origConnect.call(this, options, ...rest);
  const origWrite = socket.write.bind(socket);

  socket.write = function (data, enc, cb) {
    if (Buffer.isBuffer(data)) {
      const str = data.toString('latin1');
      // Only fix the header section (everything before the blank line \r\n\r\n)
      if (str.includes('content-length:')) {
        const headerEnd = str.indexOf('\r\n\r\n');
        if (headerEnd >= 0) {
          const fixedHeaders = str.substring(0, headerEnd).replace(/\bcontent-length:/g, 'Content-Length:');
          data = Buffer.from(fixedHeaders + str.substring(headerEnd), 'latin1');
        }
      }
    } else if (typeof data === 'string' && data.includes('content-length:')) {
      const headerEnd = data.indexOf('\r\n\r\n');
      if (headerEnd >= 0) {
        const fixedHeaders = data.substring(0, headerEnd).replace(/\bcontent-length:/g, 'Content-Length:');
        data = fixedHeaders + data.substring(headerEnd);
      }
    }
    return origWrite(data, enc, cb);
  };

  return socket;
};
