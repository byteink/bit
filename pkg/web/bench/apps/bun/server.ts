// bun's side of the tier 1-2 comparison (#5418).
const plaintext = { 'Content-Type': 'text/plain; charset=utf-8' }
const jsonType = { 'Content-Type': 'application/json' }

Bun.serve({
  hostname: '0.0.0.0',
  port: 8084,
  fetch(req: Request): Response {
    const path = new URL(req.url).pathname
    if (path === '/plaintext') {
      return new Response('Hello, World!', { headers: plaintext })
    }
    if (path === '/json') {
      return new Response(JSON.stringify({ message: 'Hello, World!' }), { headers: jsonType })
    }
    return new Response('not found', { status: 404 })
  },
})
