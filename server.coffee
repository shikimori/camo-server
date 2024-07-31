Fs          = require 'fs'
Path        = require 'path'
Url         = require 'url'
Http        = require 'http'
Https       = require 'https'
Crypto      = require 'crypto'
QueryString = require 'querystring'

port            = parseInt(process.env.PORT || 8081, 10)
version         = require(Path.resolve(__dirname, "package.json")).version
shared_key      = process.env.CAMO_KEY             || '0x24FEEDFACEDEADBEEFCAFE'
max_redirects   = process.env.CAMO_MAX_REDIRECTS   || 4
allowed_hosts   = (process.env.CAMO_ALLOWED_HOSTS  || '').split(',')
public_token    = process.env.CAMO_ALLOWED_HOSTS_PUBLIC_TOKEN || "allow"
camo_hostname   = process.env.CAMO_HOSTNAME        || "unknown"
socket_timeout  = parseInt(process.env.CAMO_SOCKET_TIMEOUT || 10, 10)
logging_enabled = process.env.CAMO_LOGGING_ENABLED || "disabled"
keep_alive      = process.env.CAMO_KEEP_ALIVE      || "false"
endpoint_path   = process.env.CAMO_ENDPOINT_PATH   || ""

endpoint_path_regex = new RegExp("^#{endpoint_path}") if endpoint_path

content_length_limit = parseInt(process.env.CAMO_LENGTH_LIMIT || 5242880, 10)
content_length_limit_redirect = process.env.CAMO_LENGTH_LIMIT_REDIRECT || false

content_403_redirect = process.env.CAMO_403_REDIRECT || false

accepted_image_mime_types = JSON.parse(Fs.readFileSync(
  Path.resolve(__dirname, "mime-types.json"),
  encoding: 'utf8'
))

debug_log = (msg) ->
  if logging_enabled == "debug"
    console.log("--------------------------------------------")
    console.log(msg)
    console.log("--------------------------------------------")

error_log = (msg) ->
  unless logging_enabled == "disabled"
    console.error("[#{new Date().toISOString()}] #{msg}")

total_connections   = 0
current_connections = 0
started_at          = new Date

default_security_headers =
  "X-Frame-Options": "deny"
  "X-XSS-Protection": "1; mode=block"
  "X-Content-Type-Options": "nosniff"
  "Content-Security-Policy": "default-src 'none'; img-src data:; style-src 'unsafe-inline'"
  "Strict-Transport-Security" : "max-age=31536000; includeSubDomains"

default_transferred_headers = [
  'if-modified-since'
  'if-none-match'
]

four_oh_four = (resp, msg, url) ->
  error_log "#{msg}: #{url?.format() or 'unknown'}"
  unless resp.headersSent
    resp.writeHead 404,
      expires: "0"
      "Cache-Control": "no-cache, no-store, private, must-revalidate"
      "X-Frame-Options"           : default_security_headers["X-Frame-Options"]
      "X-XSS-Protection"          : default_security_headers["X-XSS-Protection"]
      "X-Content-Type-Options"    : default_security_headers["X-Content-Type-Options"]
      "Content-Security-Policy"   : default_security_headers["Content-Security-Policy"]
      "Strict-Transport-Security" : default_security_headers["Strict-Transport-Security"]

  finish resp, "Not Found"

three_oh_three = (resp, location) ->
  resp.writeHead 303,
    "Location" : location

  finish resp, "See Other"

content_length_exceeded = (resp, msg, url) ->
  if content_length_limit_redirect
    three_oh_three(resp, url.format())
  else
    four_oh_four(resp, msg, url)

finish = (resp, str) ->
  current_connections -= 1
  current_connections  = 0 if current_connections < 1
  resp.connection && resp.end str

process_url = (url, transferredHeaders, resp, remaining_redirects, filename) ->
  if url.host?
    if url.protocol is 'https:'
      Protocol = Https
    else if url.protocol is 'http:'
      Protocol = Http
    else
      four_oh_four(resp, "Unknown protocol", url)
      return

    # NOTE: encodeURI fixes "TypeError [ERR_UNESCAPED_CHARACTERS] [ERR_UNESCAPED_CHARACTERS]: Request path contains unescaped characters"
    # sample of broken url https://i1.wp.com/studiodomo.jp/wordpress/wp-content/uploads/2015/07/%E9%9B%A8%E5%AE%AE%E5%93%B2%E3%81%95%E3%82%93.jpg
    queryPath = encodeURI(url.pathname)
    if url.query?
      queryPath += "?#{url.query}"

    transferredHeaders.host = url.host
    debug_log transferredHeaders

    requestOptions =
      hostname: url.hostname
      port: url.port
      path: queryPath
      headers: transferredHeaders
      timeout: socket_timeout * 1000

    if keep_alive == "false"
      requestOptions['agent'] = false

    srcReq = Protocol.get requestOptions, (srcResp) ->
      is_finished = true

      debug_log srcResp.headers

      content_length = srcResp.headers['content-length']

      if content_length > content_length_limit
        srcResp.destroy()
        content_length_exceeded(resp, "Content-Length exceeded", url)
      else
        newHeaders =
          'content-type'              : srcResp.headers['content-type'] || '' # can be undefined content-type on 304 srcResp.statusCode
          'cache-control'             : srcResp.headers['cache-control'] || 'public, max-age=31536000'
          'Camo-Host'                 : camo_hostname
          'X-Frame-Options'           : default_security_headers['X-Frame-Options']
          'X-XSS-Protection'          : default_security_headers['X-XSS-Protection']
          'X-Content-Type-Options'    : default_security_headers['X-Content-Type-Options']
          'Content-Security-Policy'   : default_security_headers['Content-Security-Policy']
          'Strict-Transport-Security' : default_security_headers['Strict-Transport-Security']

        if filename
          newHeaders['Content-Disposition'] = "inline; filename=\"#{filename}\""

        if eTag = srcResp.headers['etag']
          newHeaders['etag'] = eTag

        if expiresHeader = srcResp.headers['expires']
          newHeaders['expires'] = expiresHeader

        if lastModified = srcResp.headers['last-modified']
          newHeaders['last-modified'] = lastModified

        if origin = process.env.CAMO_TIMING_ALLOW_ORIGIN
          newHeaders['Timing-Allow-Origin'] = origin

        # Handle chunked responses properly
        if content_length?
          newHeaders['content-length'] = content_length
        if srcResp.headers['transfer-encoding']
          newHeaders['transfer-encoding'] = srcResp.headers['transfer-encoding']
        if srcResp.headers['content-encoding']
          newHeaders['content-encoding'] = srcResp.headers['content-encoding']

        if srcResp.headers['access-control-allow-origin']
          newHeaders['Access-Control-Allow-Origin'] = srcResp.headers['access-control-allow-origin']

        srcResp.on 'end', ->
          if is_finished
            finish resp
        srcResp.on 'error', ->
          if is_finished
            finish resp

        switch srcResp.statusCode
          when 301, 302, 303, 307
            srcResp.destroy()
            if remaining_redirects <= 0
              four_oh_four(resp, "Exceeded max depth", url)
            else if !srcResp.headers['location']
              four_oh_four(resp, "Redirect with no location", url)
            else
              is_finished = false
              newUrl = Url.parse srcResp.headers['location']
              unless newUrl.host? and newUrl.hostname?
                newUrl.host = newUrl.hostname = url.hostname
                newUrl.protocol = url.protocol

              debug_log "Redirected to #{newUrl.format()}"
              process_url newUrl, transferredHeaders, resp, remaining_redirects - 1, filename
          when 304
            srcResp.destroy()
            resp.writeHead srcResp.statusCode, newHeaders
            finish resp, "Not Modified"
          else
            if srcResp.statusCode == 403 && content_403_redirect
              srcResp.destroy()
              three_oh_three(resp, url.format())
              return

            contentType = newHeaders['content-type']

            unless contentType?
              lookup = MimeTypes.lookup url.pathname
              if lookup is no
                srcResp.destroy()
                four_oh_four(resp, "No content-type returned", url)
                return
              newHeaders['content-type'] = contentType = lookup

            contentTypePrefix = contentType.split(";")[0].toLowerCase()

            unless contentTypePrefix in accepted_image_mime_types
              srcResp.destroy()
              four_oh_four(resp, "Non-Image content-type returned '#{contentTypePrefix}'", url)
              return

            debug_log newHeaders

            resp.writeHead srcResp.statusCode, newHeaders
            srcResp.pipe resp

    srcReq.setTimeout (socket_timeout * 1000), ->
      srcReq.abort()
      four_oh_four resp, "Socket timeout", url

    srcReq.on 'error', (error) ->
      four_oh_four(resp, "Client Request error #{error.stack}", url)

    resp.on 'close', ->
      error_log("Request aborted")
      srcReq.abort()

    resp.on 'error', (e) ->
      error_log("Request error: #{e}")
      srcReq.abort()
  else
    four_oh_four(resp, "No host found " + url.host, url)

# decode a string of two char hex digits
hexdec = (str) ->
  if str and str.length > 0 and str.length % 2 == 0 and not str.match(/[^0-9a-f]/)
    buf = new Buffer.alloc(str.length / 2)
    for i in [0...str.length] by 2
      buf[i/2] = parseInt(str[i..i+1], 16)
    buf.toString()

server = Http.createServer (req, resp) ->
  if req.method != 'GET' || req.url == '/'
    resp.writeHead 200, default_security_headers
    resp.end 'hwhat'
  else if req.url == '/favicon.ico'
    resp.writeHead 200, default_security_headers
    resp.end 'ok'
  else if req.url == '/status'
    resp.writeHead 200, default_security_headers
    resp.end "ok #{current_connections}/#{total_connections} since #{started_at.toString()}"
  else
    total_connections   += 1
    current_connections += 1
    url = Url.parse req.url
    user_agent = process.env.CAMO_HEADER_VIA or= "Camo Asset Proxy #{version}"

    transferredHeaders =
      'Via'                     : user_agent
      'User-Agent'              : user_agent
      'Accept'                  : req.headers.accept ? 'image/*'
      'Accept-Encoding'         : req.headers['accept-encoding'] ? ''
      "X-Frame-Options"         : default_security_headers["X-Frame-Options"]
      "X-XSS-Protection"        : default_security_headers["X-XSS-Protection"]
      "X-Content-Type-Options"  : default_security_headers["X-Content-Type-Options"]
      "Content-Security-Policy" : default_security_headers["Content-Security-Policy"]

    for header in default_transferred_headers
      transferredHeaders[header] = req.headers[header] if req.headers[header]

    delete(req.headers.cookie)

    pathname = if endpoint_path_regex
      url.pathname.replace endpoint_path_regex, ''
    else
      url.pathname

    [query_digest, encoded_url] = pathname.replace(/^\//, '').split("/", 2)

    if encoded_url = hexdec(encoded_url)
      url_type = 'path'
      dest_url = encoded_url
    else
      url_type = 'query'
      query_params = QueryString.parse(url.query)
      dest_url = query_params.url
      filename = query_params.filename?.replace(/[^\x00-\xFF]/g, '')

    debug_log({
      type:     url_type
      url:      req.url
      headers:  req.headers
      dest:     dest_url
      filename: filename
      digest:   query_digest
    })

    if req.headers['via'] && req.headers['via'].indexOf(user_agent) != -1
      return four_oh_four(resp, "Requesting from self")

    if url.pathname? && dest_url
      hmac = Crypto.createHmac("sha1", shared_key)

      try
        hmac.update(dest_url, 'utf8')
      catch error
        return four_oh_four(resp, "could not create checksum")

      hmac_digest = hmac.digest('hex')

      # added .replace(/&amp;/, '&') to compensate url encoding in shkimori
      url = Url.parse dest_url.replace(/&amp;/, '&')
      if hmac_digest == query_digest || (allowed_hosts.indexOf(url.hostname) != -1 && query_params.token == public_token)
        process_url url, transferredHeaders, resp, max_redirects, filename
      else
        four_oh_four(resp, "checksum mismatch #{hmac_digest}:#{query_digest}")
    else
      four_oh_four(resp, "No pathname provided on the server")

console.log "SSL-Proxy running on #{port} with node:#{process.version} pid:#{process.pid} version:#{version}."

server.listen port
