import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const script = fs.readFileSync(new URL('../Sources/BridgeCore/Resources/autofill.js', import.meta.url), 'utf8');
function page({kind = 'credentials', origin = 'https://login.example.test', action = '/login', method = 'post'} = {}) {
  let clicks = 0;
  class Input {
    constructor() { this.disabled = false; this.readOnly = false; this.events = []; }
    get value() { return this._value || ''; }
    set value(value) { this._value = value; }
    getClientRects() { return [1]; }
    dispatchEvent(event) { this.events.push(event.type); }
  }
  const username = new Input(), password = new Input(), otp = new Input();
  const submit = {getClientRects: () => [1], textContent: 'Sign in', click: () => { clicks++; }};
  const form = {method, getAttribute: () => action, querySelectorAll: () => [submit]};
  for (const field of [username, password, otp]) field.form = form;
  const selectors = kind.startsWith('otp') ? {'input[autocomplete="one-time-code"]': [otp]} : {
    'input[autocomplete="username"]': [username], 'input[autocomplete="current-password"]': [password]
  };
  if (kind === 'otp-password-type') selectors['input[type="password"]:not([autocomplete="new-password"])'] = [otp];
  const window = {}; window.top = window;
  const context = vm.createContext({window, document: {querySelectorAll: s => selectors[s] || []},
    location: {origin, href: `${origin}/login`}, URL, HTMLInputElement: Input,
    Event: class { constructor(type) { this.type = type; } }});
  function run(overrides = {}) {
    Object.assign(context, {expectedOrigin: 'https://login.example.test:443', username: 'test-user',
      password: 'test-password', otpCode: '123456', completedSteps: [], actionMode: 'submit'}, overrides);
    return vm.runInContext(`(() => { ${script} })()`, context);
  }
  return {run, username, password, otp, get clicks() { return clicks; }};
}

let checks = 0;
function check(name, body) { body(); checks++; console.log(`PASS  ${name}`); }
check('Inspect never writes or submits; credentials submit once', () => {
  const p = page();
  assert.equal(p.run({actionMode: 'inspect'}).status, 'ready');
  assert.equal(p.username.value, ''); assert.equal(p.clicks, 0);
  assert.equal(p.run().status, 'submitted');
  assert.equal(p.username.value, 'test-user'); assert.equal(p.password.value, 'test-password');
  assert.equal(p.run().status, 'already-submitted'); assert.equal(p.clicks, 1);
});
check('A failed password never auto-retries in a new document', () => {
  const p = page(); assert.equal(p.run({completedSteps: ['username', 'password']}).status, 'already-submitted');
  assert.equal(p.password.value, ''); assert.equal(p.clicks, 0);
});
check('Separate OTP step is filled after the credential step', () => {
  const p = page({kind: 'otp'});
  assert.equal(p.run({completedSteps: ['username', 'password']}).status, 'submitted');
  assert.equal(p.otp.value, '123456'); assert.equal(p.clicks, 1);
});
check('Missing OTP leaves challenge for the user', () => {
  const p = page({kind: 'otp'}); assert.equal(p.run({otpCode: ''}).status, 'needs-otp'); assert.equal(p.clicks, 0);
});
check('Masked OTP fields are never treated as password fields', () => {
  const p = page({kind: 'otp-password-type'});
  const result = p.run({completedSteps: ['username', 'password']});
  assert.equal(result.status, 'submitted');
  assert.deepEqual(Array.from(result.steps), ['otp']);
  assert.equal(p.otp.value, '123456'); assert.equal(p.clicks, 1);
});
check('Lookalike and redirected origins receive no credentials', () => {
  const p = page({origin: 'https://login.example.test.evil.test'});
  assert.equal(p.run().status, 'wrong-origin'); assert.equal(p.password.value, ''); assert.equal(p.clicks, 0);
});
check('Cross-origin form submissions are not filled', () => {
  const p = page({action: 'https://other.example/collect'});
  assert.equal(p.run().status, 'manual'); assert.equal(p.password.value, ''); assert.equal(p.clicks, 0);
});
check('GET forms never receive passwords', () => {
  const p = page({method: 'get'}); assert.equal(p.run().status, 'manual'); assert.equal(p.password.value, '');
});
check('Quotes and script-like characters stay literal field values', () => {
  const p = page(); const literal = '\"; throw new Error("injection"); //';
  assert.equal(p.run({username: literal, password: literal}).status, 'submitted');
  assert.equal(p.username.value, literal); assert.equal(p.password.value, literal);
});
console.log(`${checks} autofill checks; 0 failures`);
