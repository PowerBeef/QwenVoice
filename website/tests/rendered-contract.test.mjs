import assert from "node:assert/strict";
import test from "node:test";
import { renderRepositoryApp, validateRenderedMarkup } from "../scripts/rendered-contract.mjs";

test("the rendered application satisfies the accessibility contract", async () => {
  assert.deepEqual(validateRenderedMarkup(await renderRepositoryApp()), []);
});

test("rendered controls and labels fail closed", () => {
  const errors = validateRenderedMarkup(
    '<nav></nav><main id="main-content"><h1>Title</h1><button></button><textarea id="x"></textarea></main><footer></footer>',
  );
  assert.ok(errors.some((error) => error.includes("skip link")));
  assert.ok(errors.some((error) => error.includes("button has no accessible name")));
  assert.ok(errors.some((error) => error.includes("textarea has no accessible label")));
});
