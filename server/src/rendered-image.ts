import jpeg from "jpeg-js";

export interface NormalizedRegion {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface PixelBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface RgbaImage {
  width: number;
  height: number;
  data: Uint8Array;
}

const INTEGER_TOLERANCE = 1e-9;
const FALLING_QUALITIES = [90, 80, 70, 60, 50, 40, 30];

export function decodeJpeg(encoded: Buffer): RgbaImage {
  return jpeg.decode(encoded, { useTArray: true, formatAsRGBA: true, maxResolutionInMP: 200, maxMemoryUsageInMB: 2048 });
}

export function encodeWithin(image: RgbaImage, maxBytes: number): Buffer | undefined {
  for (const quality of FALLING_QUALITIES) {
    const encoded = jpeg.encode(image, quality).data;
    if (encoded.length <= maxBytes) return encoded;
  }
  return undefined;
}

interface CellSpans {
  first: Int32Array;
  offset: Int32Array;
  weight: Float64Array;
}

function cellSpans(size: number, cells: number): CellSpans {
  const step = size / cells;
  const first = new Int32Array(cells);
  const offset = new Int32Array(cells + 1);
  const weights: number[] = [];
  for (let cell = 0; cell < cells; cell++) {
    const low = cell * step, high = (cell + 1) * step;
    first[cell] = Math.floor(low);
    offset[cell] = weights.length;
    for (let source = first[cell]; source < Math.min(size, Math.ceil(high)); source++) {
      weights.push(Math.min(source + 1, high) - Math.max(source, low));
    }
  }
  offset[cells] = weights.length;
  return { first, offset, weight: Float64Array.from(weights) };
}

export function areaAverage(
  width: number, height: number, targetWidth: number, targetHeight: number, valueAt: (pixel: number) => number,
): Float64Array {
  const columns = cellSpans(width, targetWidth), rows = cellSpans(height, targetHeight);
  const area = (width / targetWidth) * (height / targetHeight);
  const averages = new Float64Array(targetWidth * targetHeight);
  for (let y = 0; y < targetHeight; y++) {
    for (let x = 0; x < targetWidth; x++) {
      let total = 0;
      for (let row = rows.offset[y], sy = rows.first[y]; row < rows.offset[y + 1]; row++, sy++) {
        const base = sy * width, wy = rows.weight[row];
        for (let column = columns.offset[x], sx = columns.first[x]; column < columns.offset[x + 1]; column++, sx++) {
          total += valueAt(base + sx) * columns.weight[column] * wy;
        }
      }
      averages[y * targetWidth + x] = total / area;
    }
  }
  return averages;
}

export function scaleToEdge(image: RgbaImage, edge: number): RgbaImage {
  const scale = edge / Math.max(image.width, image.height);
  const width = Math.max(1, Math.round(image.width * scale));
  const height = Math.max(1, Math.round(image.height * scale));
  const data = new Uint8Array(width * height * 4);
  for (let channel = 0; channel < 4; channel++) {
    const averages = areaAverage(image.width, image.height, width, height, (pixel) => image.data[pixel * 4 + channel]);
    for (let i = 0; i < averages.length; i++) data[i * 4 + channel] = (averages[i] + 0.5) | 0;
  }
  return { width, height, data };
}

function snapped(value: number): number {
  const nearest = Math.round(value);
  return Math.abs(value - nearest) < INTEGER_TOLERANCE ? nearest : value;
}

export function pixelBox(region: NormalizedRegion, width: number, height: number): PixelBox {
  const left = Math.floor(snapped(region.x * width));
  const top = Math.floor(snapped(region.y * height));
  const right = Math.min(width, Math.max(left + 1, Math.ceil(snapped((region.x + region.width) * width))));
  const bottom = Math.min(height, Math.max(top + 1, Math.ceil(snapped((region.y + region.height) * height))));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function cutPixels(image: RgbaImage, box: PixelBox): Buffer {
  const data = Buffer.alloc(box.width * box.height * 4);
  for (let y = 0; y < box.height; y++) {
    const start = ((box.y + y) * image.width + box.x) * 4;
    data.set(image.data.subarray(start, start + box.width * 4), y * box.width * 4);
  }
  return data;
}
