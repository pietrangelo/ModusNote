// Trusted Types default policy, loaded before anything else (see _headers).
// Code that builds a script URL without a policy of its own (Emscripten's
// worker loader in Flutter's skwasm) gets it only for this origin or a blob
// this page created. Strings never become HTML or script: any attempt throws.
(() => {
  if (!window.trustedTypes || !trustedTypes.createPolicy) return;
  const refuse = () => {
    throw new TypeError('Blocked by the Modus Notes Trusted Types policy.');
  };
  trustedTypes.createPolicy('default', {
    createHTML: refuse,
    createScript: refuse,
    createScriptURL: (input) => {
      const url = new URL(input, document.baseURI);
      const ours = url.origin === location.origin ||
        (url.protocol === 'blob:' && input.startsWith('blob:' + location.origin + '/'));
      if (!ours) refuse();
      return input;
    },
  });
})();
