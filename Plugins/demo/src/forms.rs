//! Forms: every kind of field, one that becomes a detail and one a list, errors, more fields than fit, and
//! the least a form can be.

use crate::data::{self, Rng};
use crate::{say, Screen};
use dock2_plugin::*;
use std::collections::BTreeMap;

type Values = BTreeMap<String, String>;

fn value<'a>(values: &'a Values, id: &str) -> &'a str {
    values.get(id).map_or("", String::as_str)
}

const PLANS: &[(&str, &str)] = &[("free", "Free"), ("pro", "Pro"), ("team", "Team")];

// ---- every field ----------------------------------------------------------------------------------

#[derive(Default)]
pub struct Everything {
    /// What the form last submitted, valid: shown as a detail in its place.
    saved: Option<Values>,
    /// What the fields hold when the form is drawn afresh: after Edit Again.
    values: Values,
    errors: Values,
}

impl Everything {
    fn check(values: &Values) -> Values {
        let mut errors = Values::new();
        if value(values, "name").trim().is_empty() {
            errors.insert("name".into(), "A name, please".into());
        }
        let email = value(values, "email");
        if !email.split_once('@').is_some_and(|(user, host)| !user.is_empty() && host.contains('.')) {
            errors.insert("email".into(), "That doesn't look like an email address".into());
        }
        if value(values, "password").chars().count() < 8 {
            errors.insert("password".into(), "Eight characters or more".into());
        }
        errors
    }
}

impl Screen for Everything {
    fn render(&self, view: &str) -> ViewNode {
        if let Some(saved) = &self.saved {
            let plan = PLANS.iter().find(|(id, _)| *id == value(saved, "plan")).map_or("—", |(_, title)| title);
            let or_dash = |text: &str| if text.is_empty() { "—".to_string() } else { text.to_string() };
            return Detail::new(view)
                .body("**Saved.** The form became this detail, under the same view id.")
                .row("Name", value(saved, "name"))
                .row("Email", value(saved, "email"))
                .masked("Password")
                .row("Notes", &or_dash(value(saved, "notes")))
                .row("Newsletter", if value(saved, "newsletter") == "true" { "On" } else { "Off" })
                .row("Plan", plan)
                .row("Starts", value(saved, "starts"))
                .row("Folder", &or_dash(value(saved, "folder")))
                .status(&["Saved", "Demo"])
                .actions(vec![Action::new("edit", "Edit Again").icon(Icon::symbol("pencil")), Action::new("done", "Done")])
                .into();
        }
        let preset = |id: &str, default: &str| self.values.get(id).cloned().unwrap_or_else(|| default.into());
        let error = |id: &str| self.errors.get(id).map(String::as_str);
        Form::new(view, "Save")
            .title("Every Field")
            .field(Field::new("name", "Name", FieldKind::Text).placeholder("Ada Lovelace").value(&preset("name", "")).error(error("name")))
            .field(Field::new("email", "Email", FieldKind::Text).placeholder("ada@example.com").value(&preset("email", "")).error(error("email")))
            .field(Field::new("password", "Password", FieldKind::Secure).placeholder("Eight characters or more").error(error("password")))
            .field(Field::new("notes", "Notes", FieldKind::Multiline).value(&preset("notes", "Two lines\nof notes")))
            .field(Field::new("newsletter", "Send me the newsletter", FieldKind::Toggle).value(&preset("newsletter", "true")))
            .field(Field::new("plan", "Plan", FieldKind::Choice).options(PLANS).value(&preset("plan", "pro")))
            .field(Field::new("starts", "Starts", FieldKind::Date).value(&preset("starts", "2026-12-01")))
            .field(Field::new("folder", "Folder", FieldKind::Folder).placeholder("~/Documents").value(&preset("folder", "")))
            .into()
    }

    fn submit(&mut self, _view: &str, values: &Values, _out: &mut Effects) -> bool {
        self.errors = Self::check(values);
        if self.errors.is_empty() {
            self.saved = Some(values.clone());
        }
        true
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "edit" => self.values = self.saved.take().unwrap_or_default(),
            "done" => {
                out.pop_view();
                return false;
            }
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}

// ---- sign in, then a list -------------------------------------------------------------------------

#[derive(Default, PartialEq)]
enum Phase {
    #[default]
    SigningIn,
    Opening,
    Open,
}

#[derive(Default)]
pub struct SignIn {
    phase: Phase,
    error: Option<String>,
}

impl Screen for SignIn {
    fn render(&self, view: &str) -> ViewNode {
        if self.phase == Phase::SigningIn {
            return Form::new(view, "Sign In")
                .title("Sign in to demo.example.com")
                .field(Field::new("email", "Email", FieldKind::Text).placeholder("you@example.com"))
                .field(Field::new("password", "Master Password", FieldKind::Secure).error(self.error.as_deref()))
                .into();
        }
        let mut rng = Rng::new(25);
        let symbols = ["key.fill", "creditcard.fill", "person.text.rectangle.fill", "note.text", "wifi"];
        let mut list = List::new(view).title("Vault").loading(self.phase == Phase::Opening).actions(vec![Action::new("sign-out", "Sign Out").destructive()]);
        if self.phase == Phase::Open {
            list = list.items(
                (0..25)
                    .map(|n| {
                        let site = data::words(&mut rng, 1);
                        Item::new(&format!("{n}"), &site)
                            .subtitle(&format!("{}@example.com", data::words(&mut rng, 1).to_lowercase()))
                            .icon(Icon::symbol(symbols[n % symbols.len()]).tint(Tint::Blue))
                            .actions(vec![Action::new("password", "Copy Password"), Action::new("username", "Copy Username")])
                    })
                    .collect(),
            );
        }
        list.into()
    }

    fn submit(&mut self, view: &str, values: &Values, out: &mut Effects) -> bool {
        if value(values, "password") == "wrong" {
            self.error = Some("That password is wrong: any other will do".into());
            return true;
        }
        self.error = None;
        self.phase = Phase::Opening;
        out.timer(&format!("{view}/open"), 800, false);
        true
    }

    fn timer(&mut self, _view: &str, _name: &str, _out: &mut Effects) -> bool {
        self.phase = Phase::Open;
        true
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "password" => {
                out.copy("correct horse battery staple", true);
                out.dismiss();
                out.toast("Copied password");
            }
            "username" => {
                out.copy("ada@example.com", false);
                out.dismiss();
                out.toast("Copied username");
            }
            "sign-out" => {
                self.phase = Phase::SigningIn;
                return true;
            }
            _ => say(action, item, out),
        }
        false
    }

    fn closed(&mut self, view: &str, out: &mut Effects) {
        out.cancel_timer(&format!("{view}/open"));
    }
}

// ---- errors ---------------------------------------------------------------------------------------

#[derive(Default)]
pub struct Errors {
    /// The errors the last submit found; before one, every field's.
    checked: Option<Values>,
}

impl Errors {
    fn check(values: &Values) -> Values {
        let rules: [(&str, bool, &str); 7] = [
            ("username", value(values, "username").chars().count() >= 3, "At least three characters"),
            ("password", value(values, "password").chars().count() >= 8, "Eight characters or more"),
            ("notes", !value(values, "notes").trim().is_empty(), "Say something"),
            ("agree", value(values, "agree") == "true", "Agree to go on"),
            ("plan", !value(values, "plan").is_empty(), "Pick a plan"),
            ("day", value(values, "day") >= "2027-01-01", "A day in 2027 or later"),
            ("folder", value(values, "folder").starts_with('/'), "A path from /"),
        ];
        rules.iter().filter(|(_, ok, _)| !ok).map(|(id, _, message)| (id.to_string(), message.to_string())).collect()
    }
}

impl Screen for Errors {
    fn render(&self, view: &str) -> ViewNode {
        let everything = Self::check(&Values::new());
        let errors = self.checked.as_ref().unwrap_or(&everything);
        let error = |id: &str| errors.get(id).map(String::as_str);
        let plans = [&[("", "Choose…")][..], PLANS].concat();
        Form::new(view, "Check")
            .title("Errors Shown")
            .field(Field::new("username", "Username", FieldKind::Text).value("a").error(error("username")))
            .field(Field::new("password", "Password", FieldKind::Secure).error(error("password")))
            .field(Field::new("notes", "Notes", FieldKind::Multiline).error(error("notes")))
            .field(Field::new("agree", "I agree to the made-up terms", FieldKind::Toggle).value("false").error(error("agree")))
            .field(Field::new("plan", "Plan", FieldKind::Choice).options(&plans).value("").error(error("plan")))
            .field(Field::new("day", "Day", FieldKind::Date).value("2020-01-01").error(error("day")))
            .field(Field::new("folder", "Folder", FieldKind::Folder).value("nowhere").error(error("folder")))
            .into()
    }

    fn submit(&mut self, _view: &str, values: &Values, out: &mut Effects) -> bool {
        let errors = Self::check(values);
        if errors.is_empty() {
            out.toast("Every field is right");
            out.pop_view();
            return false;
        }
        self.checked = Some(errors);
        true
    }
}

// ---- more fields than fit -------------------------------------------------------------------------

pub struct Long;

impl Screen for Long {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(16);
        (1..=16)
            .fold(Form::new(view, "Submit").title("More Fields Than Fit"), |form, n| {
                form.field(Field::new(&format!("field-{n}"), &format!("Field {n}"), FieldKind::Text).placeholder(&data::words(&mut rng, 3)))
            })
            .into()
    }
}

// ---- one toggle -----------------------------------------------------------------------------------

pub struct Tiny;

impl Screen for Tiny {
    fn render(&self, view: &str) -> ViewNode {
        Form::new(view, "Apply").field(Field::new("enabled", "Turn the made-up thing on", FieldKind::Toggle).value("false")).into()
    }

    fn submit(&mut self, _view: &str, values: &Values, out: &mut Effects) -> bool {
        out.toast(if value(values, "enabled") == "true" { "It's on" } else { "It's off" });
        false
    }
}
