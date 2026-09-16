// express's side of the tier 1-2 comparison (#5418). etag and x-powered-by
// are off: neither of the other five servers computes an entity tag or adds
// a vanity header, so leaving them on would time express against a different
// response than everyone else is serving.
const express = require('express')

const app = express()
app.set('etag', false)
app.disable('x-powered-by')

// setHeader, not res.set: express's res.set appends the mime database's
// default charset to a Content-Type that has none, which would make this the
// only server of the six sending `application/json; charset=utf-8`.
app.get('/plaintext', (req, res) => {
  res.setHeader('Content-Type', 'text/plain; charset=utf-8')
  res.send('Hello, World!')
})

// A Buffer, not the string: res.send appends `; charset=utf-8` to a STRING
// body's Content-Type as well. The buffer path leaves the header alone, and
// express still sets Content-Length and writes the response itself.
app.get('/json', (req, res) => {
  res.setHeader('Content-Type', 'application/json')
  res.send(Buffer.from(JSON.stringify({ message: 'Hello, World!' })))
})

app.listen(8083, '0.0.0.0')
