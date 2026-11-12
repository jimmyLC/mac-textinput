import releases from './releases.json' with { type: 'json' };

const CSP = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " +
  "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function secure(response) {
  const headers = new Headers(response.headers);
  headers.set('Content-Security-Policy', CSP);
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  headers.set('Strict-Transport-Security', 'max-age=31536000');
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

// Only files listed in releases.json can be served: never arbitrary bucket keys.
async function download(request, env) {
  const [, , version, name, ...rest] = new URL(request.url).pathname.split('/');
  const asset = rest.length === 0 && Object.hasOwn(releases, version) && Object.hasOwn(releases[version], name) && releases[version][name];
  if (!asset) return new Response('Not found', { status: 404 });
  if (!env.RELEASES) return new Response('Download temporarily unavailable', { status: 503 });
  const object = await env.RELEASES.get(`${version}/${name}`);
  if (!object?.body || object.size !== asset.bytes) return new Response('Download temporarily unavailable', { status: 503 });
  return new Response(request.method === 'HEAD' ? null : object.body, {
    headers: {
      'Content-Type': name.endsWith('.dmg') ? 'application/x-apple-diskimage' : name.endsWith('.zip') ? 'application/zip' : name.endsWith('.json') ? 'application/json' : name.endsWith('.txt') ? 'text/plain; charset=utf-8' : 'application/octet-stream',
      'Content-Disposition': `attachment; filename="${name}"`,
      'Content-Length': String(object.size),
      'Cache-Control': 'public, max-age=86400, immutable',
      'X-Robots-Tag': 'noindex'
    }
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') return secure(new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } }));
    if (url.pathname === '/releases.json') {
      return secure(new Response(JSON.stringify(releases), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } }));
    }
    if (url.pathname.startsWith('/downloads/')) return secure(await download(request, env));
    return secure(await env.ASSETS.fetch(request));
  }
};
