# AIP signing protocol

Reference for the server side and for [manual signing](aip.md#advanced-manual-signing). The
interceptors implement all of this for you; you do not need this page to integrate the SDK.

## Request

```
cs-proof: <base64 envelope>
```

The envelope contains the access token, a one-time request id, a Unix timestamp, the request hash,
and the ECDSA signature. The server verifies it against the public key the device registered during
attestation.

## Response

Headers the server attaches:

```
cs-timestamp: <unix_seconds>
cs-signature: <signature>
```

Payload the server signs:

```
{statusCode}.{path}[?{canonicalQuery}].{timestamp}.{SHA256(responseBody)}
```

Example:

```
200./api/v1/users?page=2&sort=name.1746700000.e3b0c44298fc1c149afbf4c8996fb924...
```

## Rules

- **Timestamp:** must be within **±30 seconds** of the device clock.
- **Path:** the raw URL path, never decoded or normalized.
- **Query:** included in canonical form, or dropped together with the `?` when there is none. Each
  key and value is percent-decoded (`+` stays a literal `+`), re-encoded per RFC 3986 with
  uppercase hex, then pairs are sorted by key and by value and joined with `&`. This makes the
  signature independent of parameter order and of how a proxy re-encoded the query.
- **Body hash:** lowercase hex SHA-256.
- **Unsigned responses:** a `2xx` response without `cs-timestamp` / `cs-signature` is rejected
  (`aipMissingHeader`). A non-`2xx` response without them is accepted as is, so gateway and
  infrastructure errors keep their real status. A response that carries the headers is always
  verified, whatever its status.

## Body normalization (request)

| Content type | What is hashed |
|---|---|
| JSON, text, and everything else | The body bytes as sent |
| `multipart/form-data` | Text fields only (file parts are skipped), sorted by field name, JSON-encoded |

Both interceptors apply this automatically, including for Dio `FormData` and `http.MultipartRequest`.
