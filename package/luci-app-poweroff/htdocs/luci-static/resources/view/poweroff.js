// SPDX-License-Identifier: GPL-2.0-only

"use strict";
"require view";
"require fs";
"require ui";

return view.extend({
  handlePowerOff: function () {
    var cancel = E(
      "button",
      { class: "btn", click: ui.hideModal },
      _("Cancel"),
    );
    var confirm = E(
      "button",
      {
        class: "btn cbi-button-negative",
        click: function () {
          confirm.disabled = true;
          cancel.disabled = true;

          return fs
            .exec("/sbin/poweroff")
            .then(function (result) {
              if (result.code !== 0)
                throw new Error(
                  _("Power off failed (exit code %s): %s").format(
                    result.code,
                    result.stderr || _("No error output."),
                  ),
                );

              ui.showModal(_("Shutting down…"), [
                E(
                  "p",
                  { class: "spinning" },
                  _("The device is shutting down."),
                ),
              ]);
            })
            .catch(function (error) {
              ui.hideModal();
              ui.addNotification(
                null,
                E(
                  "p",
                  {},
                  _("Failed to power off the device: %s").format(error.message),
                ),
                "error",
              );
            });
        },
      },
      _("Power Off"),
    );

    ui.showModal(_("Power Off"), [
      E("p", {}, _("Do you really want to power off the device?")),
      E("div", { class: "right" }, [cancel, " ", confirm]),
    ]);
  },

  render: function () {
    return E("div", { class: "cbi-map" }, [
      E("h2", {}, _("Power Off")),
      E(
        "p",
        {},
        _(
          "The device will power off. It will not start again until power is cycled or the power button is pressed.",
        ),
      ),
      E(
        "button",
        {
          class: "cbi-button cbi-button-negative",
          disabled: !L.hasViewPermission(),
          click: this.handlePowerOff.bind(this),
        },
        _("Power Off"),
      ),
    ]);
  },

  handleSave: null,
  handleSaveApply: null,
  handleReset: null,
});
