/**
 * One-shot: upload staging APK to Firebase Storage (public read).
 * Usage: GOOGLE_APPLICATION_CREDENTIALS=... node upload-staging-apk.mjs
 */
import { Storage } from '@google-cloud/storage';
import { createReadStream, statSync } from 'fs';
import { basename } from 'path';

const projectId = 'recall-spaced-staging';
const bucketName = `${projectId}.firebasestorage.app`;
const objectPath = 'public/recall-staging.apk';
const localPath =
  process.argv[2] ||
  new URL(
    '../../recall-mobile/build/app/outputs/flutter-apk/app-staging-release.apk',
    import.meta.url,
  ).pathname;

const storage = new Storage({ projectId });
const bucket = storage.bucket(bucketName);
const file = bucket.file(objectPath);

const sizeMb = (statSync(localPath).size / (1024 * 1024)).toFixed(1);
console.log(`Uploading ${basename(localPath)} (${sizeMb} MB) → gs://${bucketName}/${objectPath}`);

await bucket.upload(localPath, {
  destination: objectPath,
  resumable: true,
  metadata: {
    contentType: 'application/vnd.android.package-archive',
    cacheControl: 'public,max-age=300',
    contentDisposition: 'attachment; filename="recall-staging.apk"',
  },
});

// Public read for BillDesk / merchant verification (object ACL + IAM may vary).
try {
  await file.makePublic();
} catch (e) {
  console.warn('makePublic failed (uniform bucket-level access?):', e.message);
}

const publicUrl = `https://storage.googleapis.com/${bucketName}/${objectPath}`;
const altMedia = `https://firebasestorage.googleapis.com/v0/b/${bucketName}/o/${encodeURIComponent(objectPath)}?alt=media`;

const [meta] = await file.getMetadata();
console.log('Upload OK');
console.log('Public URL:', publicUrl);
console.log('Firebase alt=media:', altMedia);
console.log('Size:', meta.size);
