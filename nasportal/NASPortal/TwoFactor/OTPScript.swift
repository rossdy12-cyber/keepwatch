import Foundation

/// JavaScript added to every page. It watches for a one-time-code field (TrueNAS's "Two-Factor Authentication
/// Code", Authelia's six digit boxes, or any field marked autocomplete="one-time-code"), tells the app when an
/// empty one appears, and provides `__portalFillOTP(code, force)` for the app to type the code in.
enum OTPScript {
    static let messageName = "portalOTP"

    static let source = #"""
    (function () {
      if (window.__portalFillOTP) { return; }
      var hint = /(otp|one[- ]?time|2fa|two[- ]?factor|verification code|authenticator|totp|mfa)/i;
      var skipTypes = ['hidden', 'password', 'checkbox', 'radio', 'submit', 'button', 'email', 'file', 'search'];

      function visible(el) {
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && !el.disabled && !el.readOnly;
      }
      function describe(el) {
        var parts = [el.name, el.id, el.getAttribute('aria-label'), el.placeholder, el.getAttribute('autocomplete')];
        var wrapper = el.closest('[formcontrolname]');
        if (wrapper) { parts.push(wrapper.getAttribute('formcontrolname')); }
        var named = el.parentElement && el.parentElement.closest('[name]');
        if (named) { parts.push(named.getAttribute('name')); }
        if (el.labels) { for (var i = 0; i < el.labels.length; i++) { parts.push(el.labels[i].textContent); } }
        var field = el.closest('tn-form-field, ix-input, mat-form-field');
        if (field) { parts.push(field.getAttribute('aria-label')); parts.push(field.textContent.slice(0, 200)); }
        return parts.join(' ');
      }
      function candidates() {
        return Array.prototype.filter.call(document.querySelectorAll('input'), function (el) {
          return visible(el) && skipTypes.indexOf((el.type || 'text').toLowerCase()) < 0;
        });
      }
      // Strong signs of a sign-in code field. Automatic filling only uses these, so settings pages that merely
      // mention "OTP" are never typed into; the loose `hint` match is used only when you tap the code button.
      function isCodeField(el) {
        if (el.autocomplete === 'one-time-code') { return true; }
        var name = (el.name || '').toLowerCase();
        if (name === 'otp' || name === 'totp' || name === 'passcode') { return true; }
        return !!el.closest('[formcontrolname="otp"], tn-input[name="otp"], ix-input[name="otp"], .otp-input');
      }
      function find(loose) {
        var inputs = candidates();
        // Several one-character boxes (Authelia and similar).
        var boxes = inputs.filter(function (el) {
          return !!el.closest('#otp-input, [autocomplete="one-time-code"]')
            || (loose && el.maxLength === 1);
        });
        if (boxes.length >= 4) { return { boxes: boxes }; }
        var single = inputs.filter(function (el) {
          return isCodeField(el) || (loose && hint.test(describe(el)));
        });
        if (single.length) { return { single: single[0] }; }
        return null;
      }
      function setValue(el, value) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        el.focus();
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      function fillBoxes(boxes, code) {
        var first = boxes[0];
        first.focus();
        try {
          var data = new DataTransfer();
          data.setData('text/plain', code);
          first.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
        } catch (e) {}
        setTimeout(function () {
          var typed = boxes.map(function (b) { return b.value; }).join('');
          if (typed !== code) {
            boxes.slice(0, code.length).forEach(function (b, i) { setValue(b, code.charAt(i)); });
          }
        }, 120);
        boxes.forEach(function (b) { b.dataset.portalFilled = '1'; });
      }

      window.__portalFillOTP = function (code, force) {
        var found = find(!!force);
        if (!found) {
          var active = document.activeElement;
          if (force && active && active.tagName === 'INPUT') { setValue(active, code); return 'focused'; }
          return 'none';
        }
        if (found.boxes) {
          if (!force && found.boxes[0].dataset.portalFilled === '1') { return 'already'; }
          fillBoxes(found.boxes, code);
          return 'boxes';
        }
        var el = found.single;
        if (!force && el.dataset.portalFilled === '1' && el.value) { return 'already'; }
        setValue(el, code);
        el.dataset.portalFilled = '1';
        return 'single';
      };

      // Tells the app whether a sign-in code field is on screen: 'empty', 'filled' or 'gone'.
      var scheduled = false;
      var lastState = 'gone';
      function check() {
        scheduled = false;
        var found = find(false);
        var state = 'gone';
        if (found) {
          var first = found.boxes ? found.boxes[0] : found.single;
          state = first.dataset.portalFilled !== '1' && !first.value ? 'empty' : 'filled';
        }
        if (state !== lastState && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.portalOTP) {
          window.webkit.messageHandlers.portalOTP.postMessage(state);
        }
        lastState = state;
      }
      function schedule() {
        if (!scheduled) { scheduled = true; setTimeout(check, 350); }
      }
      new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
      document.addEventListener('input', schedule, true);
      document.addEventListener('visibilitychange', schedule);
      schedule();
    })();
    """#
}
