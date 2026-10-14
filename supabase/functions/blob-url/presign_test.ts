import assert from "node:assert/strict";
import test from "node:test";

import { presignUrl, r2BucketUrl, r2ObjectUrl, signRequest } from "./presign.ts";

test("matches the AWS Signature V4 presigned URL example", async () => {
  // https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html
  const url = await presignUrl({
    method: "GET",
    host: "examplebucket.s3.amazonaws.com",
    path: "/test.txt",
    region: "us-east-1",
    service: "s3",
    accessKeyId: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    date: new Date("2013-05-24T00:00:00Z"),
    expiresSeconds: 86400,
  });

  assert.equal(
    url,
    "https://examplebucket.s3.amazonaws.com/test.txt" +
      "?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
      "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
      "&X-Amz-Date=20130524T000000Z" +
      "&X-Amz-Expires=86400" +
      "&X-Amz-SignedHeaders=host" +
      "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
  );
});

test("signing extra headers changes the signature and lists them", async () => {
  const base = {
    method: "PUT",
    host: "example.r2.cloudflarestorage.com",
    path: "/bucket/key.enc",
    region: "auto",
    service: "s3",
    accessKeyId: "id",
    secretAccessKey: "secret",
    date: new Date("2026-10-11T12:00:00Z"),
    expiresSeconds: 300,
  };
  const plain = new URL(await presignUrl(base));
  const conditional = new URL(
    await presignUrl({ ...base, signedHeaders: { "If-None-Match": "*" } }),
  );

  assert.equal(
    conditional.searchParams.get("X-Amz-SignedHeaders"),
    "host;if-none-match",
  );
  assert.notEqual(
    conditional.searchParams.get("X-Amz-Signature"),
    plain.searchParams.get("X-Amz-Signature"),
  );
});

test("an R2 object lives under its workspace in the bucket", () => {
  assert.deepEqual(
    r2ObjectUrl("acct", "modus-blobs", "00112233445566778899aabbccddeeff", "blob_1-A"),
    {
      host: "acct.r2.cloudflarestorage.com",
      path: "/modus-blobs/00112233445566778899aabbccddeeff/blob_1-A.enc",
    },
  );
});

test("matches the AWS Signature V4 header example for listing a bucket", async () => {
  // https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  // ("GET Bucket (List Objects)")
  const signed = await signRequest({
    method: "GET",
    host: "examplebucket.s3.amazonaws.com",
    path: "/",
    query: { prefix: "J", "max-keys": "2" },
    region: "us-east-1",
    service: "s3",
    accessKeyId: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    date: new Date("2013-05-24T00:00:00Z"),
  });

  assert.equal(signed.url, "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J");
  assert.deepEqual(signed.headers, {
    "x-amz-content-sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "x-amz-date": "20130524T000000Z",
    Authorization:
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," +
      "SignedHeaders=host;x-amz-content-sha256;x-amz-date," +
      "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
  });
});

test("the bucket is listed at its own path", () => {
  assert.deepEqual(r2BucketUrl("acct", "modus-blobs"), {
    host: "acct.r2.cloudflarestorage.com",
    path: "/modus-blobs",
  });
});
