/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import { describe, expect, it, vi } from 'vitest';
import * as guards from '../../supabase/functions/_shared/adminModuleAuth';
import { createEnrichmentHandler } from '../../supabase/functions/enrich-prospect/handler';

const endpoints = ['discover-prospects', 'enrich-prospect', 'report-insights', 'calendly-setup', 'rename-storage-folders', 'meeting-reminders', 'r2-storage'];

// Execute the actual endpoint sources with mocked module imports and no network.
// This verifies guard placement, not just the reusable helper in isolation.
function loadEndpoint(name: string, authorized: boolean, extraEnv: Record<string,string> = {}) {
  let handler: (req: Request) => Promise<Response>;
  const rpc = vi.fn(async () => ({ data: authorized, error: null }));
  const getUser = vi.fn(async () => ({ data: { user: { id: 'verified-admin' } }, error: null }));
  const createClient = vi.fn((_url: string, _key: string, _options?: unknown) => ({ auth: { getUser }, rpc }));
  const fetch = vi.fn();
  const s3Send = vi.fn();
  const s3Create = vi.fn();
  const getSignedUrl = vi.fn(async (_client: unknown, _command: { input: Record<string,unknown> }, _options: unknown) => 'https://upload.example.invalid');
  class S3Client {
    constructor(options: unknown) { s3Create(options); }
    send = s3Send;
  }
  class Command { constructor(public input: Record<string,unknown>) {} }
  const environment: Record<string,string> = {
    SUPABASE_URL: 'https://example.invalid', SUPABASE_ANON_KEY: 'public-test-key', ...extraEnv,
  };
  const serve = (value: typeof handler) => { handler = value; };
  const source = readFileSync(resolve('supabase/functions', name, 'index.ts'), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  runInNewContext(compiled, {
    exports: {}, require: (id: string) => {
      if (id.includes('adminModuleAuth')) return guards;
      if (id === './handler.ts' && name === 'enrich-prospect') return { createEnrichmentHandler };
      if (id.includes('supabase-js')) return { createClient };
      if (id.includes('/http/server.ts')) return { serve };
      if (id === 'npm:@aws-sdk/client-s3') return { S3Client, PutObjectCommand: Command, ListObjectsV2Command: Command, DeleteObjectCommand: Command, CopyObjectCommand: Command };
      if (id === 'npm:@aws-sdk/s3-request-presigner') return { getSignedUrl };
      throw new Error(`Unexpected module: ${id}`);
    },
    Deno: { serve, env: { get: (key: string) => environment[key] } },
    fetch, Response, Request, Headers, console, URL, Date,
  });
  return { handler: handler!, createClient, rpc, getUser, fetch, s3Send, s3Create, getSignedUrl };
}

describe.each(endpoints)('%s authorization boundary', name => {
  it('does not use project/integration credentials for anonymous callers', async () => {
    const endpoint = loadEndpoint(name, false);
    const response = await endpoint.handler(new Request('https://example.invalid', { method: 'POST', body: JSON.stringify({ action: 'delete' }) }));
    expect(response.status).toBe(401);
    expect(endpoint.createClient).not.toHaveBeenCalled();
    expect(endpoint.fetch).not.toHaveBeenCalled();
    expect(endpoint.s3Create).not.toHaveBeenCalled();
  });
  it('rejects a session without the required module/full-access grant before integrations', async () => {
    const endpoint = loadEndpoint(name, false);
    const response = await endpoint.handler(new Request('https://example.invalid', {
      method: 'POST', headers: { Authorization: 'Bearer valid-customer-token' },
      body: JSON.stringify({ action: 'delete' }),
    }));
    expect(response.status).toBe(403);
    expect(endpoint.getUser).toHaveBeenCalled();
    expect(endpoint.createClient).toHaveBeenCalledTimes(1);
    expect(endpoint.createClient.mock.calls[0][1]).toBe('public-test-key');
    expect(endpoint.fetch).not.toHaveBeenCalled();
    expect(endpoint.s3Create).not.toHaveBeenCalled();
  });
});

const r2Env = { R2_ACCESS_KEY_ID: 'fake-access', R2_SECRET_ACCESS_KEY: 'fake-secret', R2_ACCOUNT_ID: 'fake-account', R2_BUCKET_NAME: 'atmos' };
it('keeps public R2 catalog lists while refusing caller-selected private buckets', async () => {
  const endpoint = loadEndpoint('r2-storage', false, r2Env);
  endpoint.s3Send.mockResolvedValueOnce({ Contents: [{ Key: 'public-photo.jpg' }] });
  const response = await endpoint.handler(new Request('https://example.invalid', {
    method: 'POST', body: JSON.stringify({ action: 'list', bucket: 'atmos', folder: 'experiencias' }),
  }));
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual([{ Key: 'public-photo.jpg' }]);
  expect(endpoint.createClient).not.toHaveBeenCalled();
  expect(endpoint.s3Send.mock.calls[0][0].input).toEqual({ Bucket: 'atmos', Prefix: 'experiencias/' });
  const privateBucket = await endpoint.handler(new Request('https://example.invalid', {
    method: 'POST', body: JSON.stringify({ action: 'list', bucket: 'private-bucket' }),
  }));
  expect(privateBucket.status).toBe(400);
  expect(endpoint.s3Create).toHaveBeenCalledTimes(1);
});

it.each(['delete','copy','get-upload-url'])('requires site access before R2 %s and permits an authorized session', async action => {
  const endpoint = loadEndpoint('r2-storage', true, r2Env);
  endpoint.s3Send.mockResolvedValue({});
  const body = JSON.stringify({ action, folder: 'home', fileName: 'photo.jpg', sourceKey: 'old.jpg', destinationKey: 'new.jpg', contentType: 'image/jpeg' });
  const anonymous = await endpoint.handler(new Request('https://example.invalid', { method: 'POST', body }));
  expect(anonymous.status).toBe(401);
  expect(endpoint.s3Create).not.toHaveBeenCalled();
  const allowed = await endpoint.handler(new Request('https://example.invalid', {
    method: 'POST', body, headers: { Authorization: 'Bearer site-admin' },
  }));
  expect(allowed.status).toBe(200);
  expect(endpoint.rpc).toHaveBeenCalledWith('has_admin_module', { p_module: 'site' });
  if (action === 'get-upload-url') {
    expect(endpoint.getSignedUrl.mock.calls[0][1].input.ContentType).toBe('image/jpeg');
  } else expect(endpoint.s3Send).toHaveBeenCalledTimes(1);
});

it('authorized Calendly setup does not echo the signing secret or provider response payload', async () => {
  const endpoint = loadEndpoint('calendly-setup', true, {
    CALENDLY_API_TOKEN: 'fake-api-token', CALENDLY_WEBHOOK_SIGNING_KEY: 'fake-signing-secret',
  });
  endpoint.fetch.mockResolvedValueOnce(new Response(JSON.stringify({ resource: { current_organization: 'org-uri', uri: 'user-uri' } })))
    .mockResolvedValueOnce(new Response(JSON.stringify({ collection: [] })))
    .mockResolvedValueOnce(new Response(JSON.stringify({ resource: { uri: 'subscription-uri' }, signing_key: 'fake-signing-secret' })));
  const response = await endpoint.handler(new Request('https://example.invalid', {
    method: 'POST', headers: { Authorization: 'Bearer valid-admin-token' },
  }));
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(body).toContain('subscription-uri');
  expect(body).not.toContain('fake-signing-secret');
  expect(body).not.toContain('signing_key');
  expect(endpoint.rpc).toHaveBeenCalledWith('is_full_admin', { _user_id: 'verified-admin' });
  expect(endpoint.fetch).toHaveBeenCalledTimes(3);
});
