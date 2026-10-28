"use strict";

/*
 * Shared settings form for the setup view (data-mode="setup") and Demo Control
 * (data-mode="control"). Adapted from the splunk-setup-page-builder reference.
 *
 * Every submit always saves, even when is_configured is already 1. Do not add
 * an is_configured guard before the save calls.
 *
 * Only non-secret settings exist in v1, so storage/passwords is not used.
 */

const APP_NAME = "lkab_kiruna_demo";
const APP_NAMESPACE = { owner: "nobody", app: APP_NAME, sharing: "app" };
const SETTINGS_CONF_FILE = "lkab_kiruna_demo_settings";
const SETTINGS_STANZA = "generator";
const INPUT_PATH = "data/inputs/kiruna_demo_gen/kiruna_demo";
const SCENARIOS = [
    "healthy-shift",
    "truck-stuck",
    "loader-stopped-drawpoint",
    "cascade-crusher-hoist",
    "recovery",
];

require(["jquery", "splunkjs/splunk", "splunkjs/mvc/simplexml/ready!"], function ($, splunkjs) {
    const root = $("#kiruna_settings");
    if (root.length === 0) {
        return;
    }
    const mode = root.data("mode") === "control" ? "control" : "setup";
    const service = new splunkjs.Service(new splunkjs.SplunkWebHttp(), APP_NAMESPACE);

    loadCurrent();
    $("#kiruna_save").on("click", function (e) {
        e.preventDefault();
        submit();
    });

    function readForm() {
        return {
            scenario: String($("#kiruna_scenario").val() || "").trim(),
            generator_enabled: $("#kiruna_generator_enabled").is(":checked"),
            presentation_shift: $("#kiruna_presentation_shift").is(":checked"),
            backfill_days: String($("#kiruna_backfill_days").val() || "").trim(),
        };
    }

    function validate(v) {
        const errors = [];
        if (SCENARIOS.indexOf(v.scenario) < 0) {
            errors.push("Scenario must be one of: " + SCENARIOS.join(", ") + ".");
        }
        if (!/^(?:[0-9]|1[0-4])$/.test(v.backfill_days)) {
            errors.push("Backfill days must be a whole number from 0 through 14.");
        }
        return errors;
    }

    async function submit() {
        clearMessages();
        const v = readForm();
        const errors = validate(v);
        if (errors.length > 0) {
            showErrors(errors);
            return;
        }
        let stage = "Saving [generator] in " + SETTINGS_CONF_FILE + ".conf";
        try {
            await saveConfigSetting({
                scenario: v.scenario,
                generator_enabled: v.generator_enabled ? "true" : "false",
                presentation_shift: v.presentation_shift ? "true" : "false",
                backfill_days: v.backfill_days,
            });
            stage = (v.generator_enabled ? "Enabling" : "Disabling") + " the generator input";
            await post(INPUT_PATH + "/" + (v.generator_enabled ? "enable" : "disable"), {});
            if (mode === "setup") {
                stage = "Marking setup complete (app.conf [install] is_configured=1)";
                await setIsConfigured(1);
                stage = "Reloading the app";
                await reloadApp();
            }
            $(".success").show();
            if (mode === "setup") {
                setTimeout(function () {
                    window.location.href = "/app/" + APP_NAME + "/shift_brief";
                }, 800);
            }
        } catch (e) {
            showErrors([describeError(stage, e)]);
        }
    }

    async function loadCurrent() {
        try {
            const stanza = await getStanza(false);
            if (!stanza) {
                return;
            }
            const p = stanza.properties();
            if (SCENARIOS.indexOf(p.scenario) >= 0) {
                $("#kiruna_scenario").val(p.scenario);
            }
            if (p.generator_enabled !== undefined) {
                $("#kiruna_generator_enabled").prop("checked", isTrue(p.generator_enabled));
            }
            if (p.presentation_shift !== undefined) {
                $("#kiruna_presentation_shift").prop("checked", isTrue(p.presentation_shift));
            }
            if (mode === "control" && /^\d+$/.test(String(p.backfill_days))) {
                $("#kiruna_backfill_days").val(p.backfill_days);
            }
        } catch (e) {
            // First run: the settings file does not exist yet.
        }
    }

    function isTrue(value) {
        return ["1", "true", "t", "yes", "y"].indexOf(String(value).toLowerCase()) >= 0;
    }

    async function getStanza(create) {
        const configs = service.configurations(APP_NAMESPACE);
        await fetchEntity(configs);
        if (!hasItem(configs, SETTINGS_CONF_FILE)) {
            if (!create) {
                return null;
            }
            await createEntity(configs, SETTINGS_CONF_FILE);
            await fetchEntity(configs);
        }
        const confFile = configs.item(SETTINGS_CONF_FILE);
        await fetchEntity(confFile);
        if (!hasItem(confFile, SETTINGS_STANZA)) {
            if (!create) {
                return null;
            }
            await createEntity(confFile, SETTINGS_STANZA);
            await fetchEntity(confFile);
        }
        const stanza = confFile.item(SETTINGS_STANZA);
        await fetchEntity(stanza);
        return stanza;
    }

    async function saveConfigSetting(properties) {
        const stanza = await getStanza(true);
        await updateEntity(stanza, properties);
    }

    async function setIsConfigured(value) {
        const configs = service.configurations(APP_NAMESPACE);
        await fetchEntity(configs);
        const appConf = configs.item("app");
        await fetchEntity(appConf);
        const install = appConf.item("install");
        await fetchEntity(install);
        await updateEntity(install, { is_configured: value });
    }

    async function reloadApp() {
        const apps = service.apps();
        await fetchEntity(apps);
        const app = apps.item(APP_NAME);
        await fetchEntity(app);
        await new Promise(function (resolve, reject) {
            app.reload(function (err) {
                if (err) reject(err); else resolve();
            });
        });
    }

    function hasItem(collection, name) {
        return collection.list().some(function (entry) { return entry.name === name; });
    }

    function fetchEntity(entity) {
        return new Promise(function (resolve, reject) {
            entity.fetch(function (err, fetched) {
                if (err) reject(err); else resolve(fetched);
            });
        });
    }

    function createEntity(collection, name) {
        return new Promise(function (resolve, reject) {
            collection.create(name, function (err, created) {
                if (err) reject(err); else resolve(created);
            });
        });
    }

    function updateEntity(entity, properties) {
        return new Promise(function (resolve, reject) {
            entity.update(properties, function (err, updated) {
                if (err) reject(err); else resolve(updated);
            });
        });
    }

    function post(path, params) {
        return new Promise(function (resolve, reject) {
            service.post(path, params, function (err, response) {
                if (err) reject(err); else resolve(response);
            });
        });
    }

    function clearMessages() {
        $(".kiruna-msg").hide();
        $("#kiruna_errors").empty();
    }

    function showErrors(messages) {
        $(".error.kiruna-msg").show();
        const list = $("#kiruna_errors");
        messages.forEach(function (m) { list.append($("<li>").text(m)); });
    }

    function describeError(stage, e) {
        let text = "Error during: " + stage;
        if (e && e.data && e.data.messages) {
            text += " - " + e.data.messages.map(function (m) { return m.type + ": " + m.text; }).join("; ");
        } else if (e && e.responseText) {
            text += " - " + e.responseText;
        } else if (e && e.status) {
            text += " - HTTP " + e.status;
        }
        return text;
    }
});
