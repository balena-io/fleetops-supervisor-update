## Overview

We'll send a script to opendoor devices over SSH that will:

1. Download rdiff.xz using resumable curl and retry logic
2. Download the appropriate compressed delta using resumable curl and retry logic
3. Download checksums.txt with retry logic
4. Will `docker save` the on-device supervisor image in the data partition and verify its checksum using checksum.txt
5. Will decompress rdiff the delta files using the xz compressor included in resinOS
6. Will apply the deltas creating a local supervisor-6.6.9.tar file
7. Will `docker load` the new supervisor and also change /etc/supervisor.conf and do the appropriate API calls to resin

**The script should not rely on the original SSH connection be left open.**

### checksums.txt

This file contains the result of `docker save <supervisor_image> | sha256sum`
for each of the supervisor versions that exist in Opendoor's fleet. This should
be used on the device to verify that we have the correct base before proceeding
to apply the diffs

### deltas/*

This contains the xz compressed rdiff delta for all the appropriate supervisor
versions. They have been created using the `rdiff` CLI tool with a block size
of 128 bytes:

```bash
# delta generation
docker save resin/armv7hf-supervisor:v4.0.0 > 4.0.0.tar
docker save resin/armv7hf-supervisor:v6.6.9 > 6.6.9.tar
rdiff signature 4.0.0.tar 4.0.0.tar.sig
rdiff delta -b 128 4.0.0.tar.sig 6.6.9.tar 4.0.0-6.6.9.delta
xz -9 4.0.0-6.6.9.delta
```

Those files should be put in a public HTTP server that supports Range: headers
so that the devices can resume in case of disconnection

### rdiff.xz

A statically compiled rdiff binary for ARM that will be used to apply the delta
on the device.
