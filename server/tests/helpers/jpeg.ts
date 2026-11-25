function segment(marker: number, body: number[]): Buffer {
  const length = body.length + 2;
  return Buffer.from([0xff, marker, length >> 8, length & 0xff, ...body]);
}

export function midGreyJpeg(width: number, height: number): Buffer {
  const blocks = Math.ceil(width / 8) * Math.ceil(height / 8);
  const scan = Buffer.alloc(Math.ceil((blocks * 2) / 8));
  const used = (blocks * 2) % 8;
  if (used) scan[scan.length - 1] = 0xff >> used;
  const onlySymbolZero = (tableClass: number) => [tableClass << 4, 1, ...new Array<number>(15).fill(0), 0];
  return Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    segment(0xdb, [0, ...new Array<number>(64).fill(1)]),
    segment(0xc0, [8, height >> 8, height & 0xff, width >> 8, width & 0xff, 1, 1, 0x11, 0]),
    segment(0xc4, [...onlySymbolZero(0), ...onlySymbolZero(1)]),
    segment(0xda, [1, 1, 0, 0, 63, 0]),
    scan,
    Buffer.from([0xff, 0xd9]),
  ]);
}

export function paddedJpeg(jpeg: Buffer, bytes: number): Buffer {
  const comments: Buffer[] = [];
  for (let missing = bytes - jpeg.length; missing > 0; missing -= 65537) {
    const text = Math.max(0, Math.min(65533, missing - 4));
    const header = Buffer.from([0xff, 0xfe, 0, 0]);
    header.writeUInt16BE(text + 2, 2);
    comments.push(header, Buffer.alloc(text, 0x20));
  }
  return Buffer.concat([jpeg.subarray(0, 2), ...comments, jpeg.subarray(2)]);
}
