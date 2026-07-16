// Hand-written types for threeExports.js — only the surface GameRender.ts
// touches. The render() signature is the fork's old 4-arg form (scene, camera,
// renderTarget, forceClear); it predates three's setRenderTarget API.

export const LinearFilter: number;
export const NearestFilter: number;
export const RGBAFormat: number;
export const UnsignedByteType: number;

export class CfxTexture {
    needsUpdate: boolean;
}

export class PlaneBufferGeometry {
    constructor(width: number, height: number);
}

export class ShaderMaterial {
    constructor(parameters: {
        uniforms: Record<string, { value: unknown }>;
        vertexShader: string;
        fragmentShader: string;
    });
}

export class Mesh {
    constructor(geometry: PlaneBufferGeometry, material: ShaderMaterial);
    position: { x: number; y: number; z: number };
}

export class Scene {
    add(...objects: Mesh[]): void;
}

export class OrthographicCamera {
    constructor(left: number, right: number, top: number, bottom: number, near: number, far: number);
    position: { x: number; y: number; z: number };
    setViewOffset(fullWidth: number, fullHeight: number, x: number, y: number, width: number, height: number): void;
}

export class WebGLRenderTarget {
    constructor(width: number, height: number, options?: {
        minFilter?: number;
        magFilter?: number;
        format?:    number;
        type?:      number;
    });
}

export class WebGLRenderer {
    readonly domElement: HTMLCanvasElement;
    autoClear: boolean;
    setSize(width: number, height: number): void;
    clear(): void;
    render(scene: Scene, camera: OrthographicCamera, renderTarget?: WebGLRenderTarget, forceClear?: boolean): void;
    readRenderTargetPixels(renderTarget: WebGLRenderTarget, x: number, y: number, width: number, height: number, buffer: Uint8Array): void;
}
