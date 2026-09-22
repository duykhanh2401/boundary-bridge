// Runs only on the initial HTTPS login origin returned by Boundary.
const trustedOrigin = new URL(expectedOrigin).origin;
if (location.origin !== trustedOrigin || window.top !== window) return {status: 'wrong-origin'};
const visible = el => el && !el.disabled && !el.readOnly && el.getClientRects().length > 0;
const find = (selectors, excluded = []) => selectors.flatMap(s => Array.from(document.querySelectorAll(s)))
  .find(el => visible(el) && !excluded.includes(el));
const inputs = Array.from(document.querySelectorAll('input')).filter(visible);
const hint = el => [el.name, el.id, el.autocomplete, el.placeholder, el.getAttribute?.('aria-label'),
  ...Array.from(el.labels || []).map(label => label.textContent)].filter(Boolean).join(' ')
  .normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
const otpHint = /(?:\botp\b|totp|one[\s_-]*time|verification[\s_-]*code|authenticator|auth[\s_-]*code|passcode|security[\s_-]*code|ma[\s_-]*(?:xac[\s_-]*thuc|otp))/;
let singleOTP = find(['input[autocomplete="one-time-code"]', 'input[name="otp"]', 'input[name="totp"]',
  'input[name="code"]', 'input[name="verificationCode"]', 'input[name="passcode"]', '#otp', '#totp', '#code'])
  || inputs.find(el => otpHint.test(hint(el)));
// Some providers use one field per digit. Never place the whole code in digit 1.
const digitFields = inputs.filter(el => el.maxLength === 1 && ['text', 'tel', 'number', 'password'].includes(el.type));
const splitOTP = [6, 8].includes(digitFields.length) &&
  digitFields.every(el => el.form === digitFields[0].form) &&
  (digitFields.includes(singleOTP) || digitFields.some(el => otpHint.test(hint(el))));
const otpFields = splitOTP ? digitFields : singleOTP ? [singleOTP] : [];
const passwordField = find(['input[autocomplete="current-password"]', 'input[type="password"]:not([autocomplete="new-password"])'], otpFields);
const user = find(['input[autocomplete="username"]', 'input[name="username"]', 'input[name="login"]',
  'input[name="email"]', 'input[name="loginfmt"]', 'input[type="email"]', '#username'], otpFields);
// An OTP challenge takes priority, even when prior credentials remain in the DOM.
// If credentials have not yet been sent and are still required, fill a combined form.
const credentialFields = [[user, 'username', username], [passwordField, 'password', password]]
  .filter(x => x[0] && !completedSteps.includes(x[1]));
let fields = otpFields.length
  ? [...credentialFields, ...otpFields.map((el, index) => [el, 'otp', splitOTP ? otpCode[index] : otpCode])]
  : [[user, 'username', username], [passwordField, 'password', password]].filter(x => x[0]);
if (!fields.length) return {status: 'waiting'};
if (otpFields.length && (!otpCode || (splitOTP && otpCode.length !== otpFields.length))) return {status: 'needs-otp'};
const steps = [...new Set(fields.map(x => x[1]))];
if (steps.some(s => completedSteps.includes(s))) return {status: 'already-submitted'};
if (typeof expectedSteps !== 'undefined' && expectedSteps.length &&
    JSON.stringify(steps) !== JSON.stringify(expectedSteps)) return {status: 'changed'};
const form = fields[fields.length - 1][0].form;
if (fields.some(x => x[0].form !== form)) return {status: 'manual'};
if (form) {
  const action = new URL(form.getAttribute('action') || location.href, location.href);
  if (action.origin !== trustedOrigin || form.method.toLowerCase() !== 'post') return {status: 'manual'};
} else if (steps.some(step => step !== 'otp')) return {status: 'manual'};
const submit = form && Array.from(form.querySelectorAll('button[type="submit"], input[type="submit"], button:not([type])'))
  .find(el => visible(el) && !/cancel|hủy|register|sign up|đăng ký|reset|forgot/i.test(el.textContent + ' ' + (el.value || '')));
if (!submit && !otpFields.length) return {status: 'manual'};
const key = '__boundaryBridgeSubmitted';
if (steps.some(s => (window[key] || []).includes(s))) return {status: 'already-submitted'};
if (actionMode === 'inspect') return {status: 'ready', steps};
for (const [field, _, value] of fields) {
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, value);
  field.dispatchEvent(new Event('input', {bubbles: true}));
  field.dispatchEvent(new Event('change', {bubbles: true}));
}
window[key] = [...(window[key] || []), ...steps];
if (submit) { submit.click(); return {status: 'submitted', steps}; }
return {status: 'filled', steps};
