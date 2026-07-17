import { describe, expect, it } from 'vitest';

import { bgLuma, luma, parseRGBA } from './contrast';

describe('parseRGBA', () => {
    it('parses rgb and rgba', () => {
        expect(parseRGBA('rgb(10, 20, 30)')).toEqual({ r: 10, g: 20, b: 30, a: 1 });
        expect(parseRGBA('rgba(0, 0, 0, 0.5)')).toEqual({ r: 0, g: 0, b: 0, a: 0.5 });
    });
    it('rejects non-color strings', () => {
        expect(parseRGBA('none')).toBeNull();
        expect(parseRGBA('')).toBeNull();
    });
});

describe('luma', () => {
    it('is 0 for black and 1 for white', () => {
        expect(luma({ r: 0, g: 0, b: 0, a: 1 })).toBe(0);
        expect(luma({ r: 255, g: 255, b: 255, a: 1 })).toBeCloseTo(1, 5);
    });
});

describe('bgLuma', () => {
    it('reads a solid dark color as low luma', () => {
        expect(bgLuma('rgb(11, 11, 12)', 'none')).toBeLessThan(0.1);
    });
    it('reads a solid light color as high luma', () => {
        expect(bgLuma('rgb(212, 212, 212)', 'none')).toBeGreaterThan(0.7);
    });
    it('treats a transparent color with no image as undetermined', () => {
        expect(bgLuma('rgba(0, 0, 0, 0)', 'none')).toBeNull();
    });
    it('averages a dark gradient to low luma', () => {
        const g = 'linear-gradient(180deg, rgb(44, 42, 40) 0%, rgb(33, 31, 29) 52%, rgb(22, 20, 18) 100%)';
        const v = bgLuma('rgba(0, 0, 0, 0)', g);
        expect(typeof v).toBe('number');
        expect(v as number).toBeLessThan(0.3);
    });
    it('averages a light gradient to high luma', () => {
        const g = 'linear-gradient(180deg, rgb(78, 192, 202) 0%, rgb(155, 227, 196) 100%)';
        expect(bgLuma('rgba(0, 0, 0, 0)', g) as number).toBeGreaterThan(0.5);
    });
    it('reads a radial gradient the same way', () => {
        const g = 'radial-gradient(120% 90% at 50% 0%, rgb(23, 17, 48) 0%, rgb(14, 11, 26) 60%)';
        expect(bgLuma('rgba(0, 0, 0, 0)', g) as number).toBeLessThan(0.2);
    });
    it('treats a url image as undetermined', () => {
        expect(bgLuma('rgba(0, 0, 0, 0)', 'url("data:image/png;base64,AAAA")')).toBe('image');
    });
});
