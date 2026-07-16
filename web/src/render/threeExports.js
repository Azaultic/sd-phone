// Deep re-exports from the vendored three.js fork (./three, patched with
// CfxTexture). Importing the fork's own barrel (three/Three.js) would pull the
// entire 350-file module graph into the chunk — its pre-class-syntax prototype
// mutation defeats Rollup's tree-shaking — so these deep paths keep the bundle
// to the renderer core. Types live in threeExports.d.ts; tsc never parses the
// fork itself.
export { CfxTexture } from './three/textures/CfxTexture.js';
export { LinearFilter, NearestFilter, RGBAFormat, UnsignedByteType } from './three/constants.js';
export { Mesh } from './three/objects/Mesh.js';
export { OrthographicCamera } from './three/cameras/OrthographicCamera.js';
export { PlaneBufferGeometry } from './three/geometries/PlaneGeometry.js';
export { Scene } from './three/scenes/Scene.js';
export { ShaderMaterial } from './three/materials/ShaderMaterial.js';
export { WebGLRenderTarget } from './three/renderers/WebGLRenderTarget.js';
export { WebGLRenderer } from './three/renderers/WebGLRenderer.js';
