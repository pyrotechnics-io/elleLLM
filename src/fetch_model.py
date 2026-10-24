"""Download the GGUF model from S3 into /tmp on a Lambda cold start.

Uses parallel ranged GETs so a multi-GB file arrives in seconds rather than
minutes. Skips the download if a warm sandbox already has the file.
"""

import os
import sys

import boto3
from boto3.s3.transfer import TransferConfig

MB = 1024 * 1024


def main(bucket: str, key: str, dest: str) -> None:
    s3 = boto3.client("s3")
    size = s3.head_object(Bucket=bucket, Key=key)["ContentLength"]
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        return

    tmp = dest + ".part"
    config = TransferConfig(
        multipart_threshold=16 * MB,
        multipart_chunksize=32 * MB,
        max_concurrency=int(os.environ.get("MODEL_DOWNLOAD_CONCURRENCY", "32")),
    )
    s3.download_file(bucket, key, tmp, Config=config)
    os.replace(tmp, dest)


if __name__ == "__main__":
    main(*sys.argv[1:4])
