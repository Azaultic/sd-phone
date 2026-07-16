import { describe, expect, it } from 'vitest';

import { computeCropRegion, LANDSCAPE_CROP, PORTRAIT_CROP, SELFIE_CROP_BIAS_X } from './crop';

const W = 1920;
const H = 1080;

describe('computeCropRegion', () => {
    it('samples the centred portrait slice at 1x', () => {
        const r = computeCropRegion(W, H, 1, 'portrait');
        expect(r.width).toBe(Math.floor(W * PORTRAIT_CROP.width));
        expect(r.height).toBe(H);
        expect(r.offsetX).toBe(Math.floor((W - r.width) / 2));
        expect(r.offsetY).toBe(0);
    });

    it('shrinks both axes by 1/zoom', () => {
        const r = computeCropRegion(W, H, 2, 'portrait');
        expect(r.width).toBe(Math.floor((W * PORTRAIT_CROP.width) / 2));
        expect(r.height).toBe(Math.floor(H / 2));
    });

    it('clamps 0.5x to the screen instead of over-sampling', () => {
        const r = computeCropRegion(W, H, 0.5, 'portrait');
        expect(r.width).toBe(Math.floor(W * Math.min(1, PORTRAIT_CROP.width / 0.5)));
        expect(r.height).toBe(H);
        expect(r.offsetY).toBe(0);
    });

    it('uses the wide band in landscape', () => {
        const r = computeCropRegion(W, H, 1, 'landscape');
        expect(r.width).toBe(Math.floor(W * LANDSCAPE_CROP.width));
        expect(r.height).toBe(Math.floor(H * LANDSCAPE_CROP.height));
    });

    it('stays centred at every zoom', () => {
        for (const zoom of [0.5, 1, 2, 5]) {
            const r = computeCropRegion(W, H, zoom, 'portrait');
            expect(r.offsetX * 2 + r.width).toBeLessThanOrEqual(W + 1);
            expect(r.offsetX).toBeGreaterThanOrEqual(0);
        }
    });

    it('slides the window left by the selfie bias', () => {
        const centred = computeCropRegion(W, H, 1, 'portrait');
        const biased  = computeCropRegion(W, H, 1, 'portrait', SELFIE_CROP_BIAS_X);
        expect(biased.width).toBe(centred.width);
        expect(biased.offsetX).toBe(centred.offsetX - Math.round(SELFIE_CROP_BIAS_X * W));
    });

    it('clamps the biased window to the screen', () => {
        const r = computeCropRegion(W, H, 1, 'portrait', 1);
        expect(r.offsetX).toBe(0);
    });
});
