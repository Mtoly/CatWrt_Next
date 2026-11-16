// SPDX-License-Identifier: GPL-2.0-only

const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const { runInNewContext } = require("node:vm");

const root = join(__dirname, "..");
const source = readFileSync(
  join(root, "htdocs/luci-static/resources/view/poweroff.js"),
  "utf8",
);

function loadView(exec = async () => ({ code: 0 }), writable = true) {
  const state = { calls: [], modals: [], notifications: [], hidden: 0 };
  const context = {
    view: { extend: (definition) => definition },
    fs: {
      exec: (...args) => {
        state.calls.push(args);
        return exec(...args);
      },
    },
    ui: {
      showModal: (title, children) => state.modals.push({ title, children }),
      hideModal: () => state.hidden++,
      addNotification: (...args) => state.notifications.push(args),
    },
    L: { hasViewPermission: () => writable },
    E: (tag, attrs, children) => ({ tag, attrs, children }),
    _: (message) => message,
  };
  state.view = runInNewContext(
    `String.prototype.format = function (...args) {
      return this.replace(/%s/g, () => String(args.shift()));
    };
    (function () { ${source} })()`,
    context,
  );
  state.open = () => {
    const rendered = state.view.render();
    const button = rendered.children.find((el) => el.tag === "button");
    button.attrs.click();
    const buttons = state.modals.at(-1).children.at(-1).children;
    return { cancel: buttons[0], confirm: buttons[2] };
  };
  return state;
}

test("render exposes one danger button and no save/apply/reset actions", () => {
  for (const writable of [true, false]) {
    const { view } = loadView(undefined, writable);
    const buttons = view.render().children.filter((el) => el.tag === "button");
    assert.equal(buttons.length, 1);
    assert.match(buttons[0].attrs.class, /cbi-button-negative/);
    assert.equal(buttons[0].attrs.disabled, !writable);
    assert.equal(view.handleSave, null);
    assert.equal(view.handleSaveApply, null);
    assert.equal(view.handleReset, null);
  }
});

test("opening and cancelling confirmation never executes poweroff", () => {
  const state = loadView();
  const { cancel } = state.open();
  assert.equal(state.modals[0].title, "Power Off");
  assert.equal(state.calls.length, 0);
  cancel.attrs.click();
  assert.equal(state.hidden, 1);
  assert.equal(state.calls.length, 0);
});

test("confirmation runs poweroff and shows shutdown", async () => {
  let finish;
  const state = loadView(() => new Promise((resolve) => (finish = resolve)));
  const { cancel, confirm } = state.open();
  const pending = confirm.attrs.click();
  assert.deepEqual(state.calls, [["/sbin/poweroff"]]);
  assert.equal(confirm.disabled, true);
  assert.equal(cancel.disabled, true);
  assert.equal(state.modals.length, 1);
  finish({ code: 0 });
  await pending;
  assert.equal(state.modals.at(-1).title, "Shutting down…");
  assert.equal(state.notifications.length, 0);
});

test("nonzero exit reports its code and stderr or a fallback", async () => {
  for (const stderr of ["Permission denied", ""]) {
    const state = loadView(async () => ({ code: 1, stderr }));
    await state.open().confirm.attrs.click();
    assert.equal(state.hidden, 1);
    assert.equal(state.modals.length, 1);
    assert.equal(state.notifications.length, 1);
    const [title, message, severity] = state.notifications[0];
    assert.equal(title, null);
    assert.equal(severity, "error");
    const detail = stderr || "No error output.";
    const expected = `Power off failed (exit code 1): ${detail}`;
    assert.equal(
      message.children,
      `Failed to power off the device: ${expected}`,
    );
  }
});

test("RPC rejection reports its concrete cause and allows retry", async () => {
  const state = loadView(async () => {
    throw new Error("RPC permission denied");
  });
  await state.open().confirm.attrs.click();
  assert.equal(state.hidden, 1);
  assert.equal(
    state.notifications[0][1].children,
    "Failed to power off the device: RPC permission denied",
  );
  await state.open().confirm.attrs.click();
  assert.equal(state.calls.length, 2);
});

test("menu uses the view and ACL grants only exec of poweroff", () => {
  const acl = JSON.parse(
    readFileSync(
      join(root, "root/usr/share/rpcd/acl.d/luci-app-poweroff.json"),
      "utf8",
    ),
  );
  assert.deepEqual(acl, {
    "luci-app-poweroff": {
      write: { file: { "/sbin/poweroff": ["exec"] } },
    },
  });
  const menu = JSON.parse(
    readFileSync(
      join(root, "root/usr/share/luci/menu.d/luci-app-poweroff.json"),
      "utf8",
    ),
  );
  assert.deepEqual(menu["admin/system/poweroff"], {
    title: "Power Off",
    order: 91,
    action: { type: "view", path: "poweroff" },
    depends: { acl: ["luci-app-poweroff"] },
  });
});

test("template and Chinese catalogue cover every view and menu message", () => {
  const ids = new Set(
    [...source.matchAll(/_\(\s*("(?:[^"\\]|\\.)*")/g)].map((match) =>
      JSON.parse(match[1]),
    ),
  );
  ids.add("Power Off");
  for (const path of ["templates/poweroff.pot", "zh_Hans/poweroff.po"]) {
    const catalogue = readFileSync(join(root, "po", path), "utf8");
    const entries = [...catalogue.matchAll(/^msgid (".+")\nmsgstr (".*")/gm)];
    const catalogueIds = new Set(entries.map((entry) => JSON.parse(entry[1])));
    assert.deepEqual(catalogueIds, ids);
    if (path.startsWith("zh_Hans")) {
      for (const [, id, translation] of entries) {
        const translated = JSON.parse(translation);
        assert.match(translated, /[\u3400-\u9fff]/);
        assert.equal(
          (translated.match(/%s/g) || []).length,
          (JSON.parse(id).match(/%s/g) || []).length,
        );
      }
    }
  }
});
