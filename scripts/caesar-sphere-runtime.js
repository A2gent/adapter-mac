// The same geometry, materials, camera and rotation as Caesar's AgentAvatar.
const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setClearColor(0, 0);
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(45, 1, 0.1, 100);
camera.position.set(0, 0, 3.25);
camera.lookAt(0, 0, 0);
const uniforms = { uTime: { value: 0 }, uAudioLevel: { value: 0 }, uMode: { value: 0 } };
const geometry = new THREE.IcosahedronGeometry(0.86, 3);
const group = new THREE.Group();
const layers = [
  [OUTLINE_FRAGMENT_SHADER, 1.045, { side: THREE.BackSide, depthWrite: false, blending: THREE.AdditiveBlending }],
  [FRAGMENT_SHADER_V2, 1, { side: THREE.FrontSide }],
  [WIREFRAME_FRAGMENT_SHADER, 1.008, { side: THREE.FrontSide, depthWrite: false, wireframe: true, blending: THREE.AdditiveBlending }],
];
for (const [fragmentShader, scale, options] of layers) {
  const mesh = new THREE.Mesh(geometry, new THREE.ShaderMaterial({ vertexShader: VERTEX_SHADER, fragmentShader, uniforms, transparent: true, ...options }));
  mesh.scale.setScalar(scale);
  group.add(mesh);
}
scene.add(group);
let visible = true;
let reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
let frame = 0;
let last = 0;
function render(now) {
  frame = 0;
  const delta = last ? Math.min((now - last) / 1000, 0.05) : 0;
  last = now;
  if (!reducedMotion) {
    uniforms.uTime.value += delta;
    group.rotation.y += delta * (uniforms.uMode.value > 0 ? 0.35 : 0.14);
    group.rotation.x += delta * (uniforms.uMode.value > 0 ? 0.08 : 0.03);
  }
  renderer.render(scene, camera);
  if (visible && !document.hidden && !reducedMotion) frame = requestAnimationFrame(render);
}
function refresh() {
  if (frame) cancelAnimationFrame(frame);
  frame = 0;
  last = 0;
  if (visible && !document.hidden) frame = requestAnimationFrame(render);
}
window.setSphereState = (mode, level, isVisible, reduceMotion) => {
  uniforms.uMode.value = mode;
  uniforms.uAudioLevel.value = level;
  visible = isVisible;
  reducedMotion = reduceMotion;
  // Audio updates must not reset the animation clock or starve requestAnimationFrame.
  if (!visible || reducedMotion || !frame) refresh();
};
new ResizeObserver(() => {
  renderer.setSize(innerWidth, innerHeight);
  camera.aspect = innerWidth / Math.max(innerHeight, 1);
  camera.updateProjectionMatrix();
  refresh();
}).observe(document.body);
document.addEventListener('visibilitychange', refresh);
refresh();
