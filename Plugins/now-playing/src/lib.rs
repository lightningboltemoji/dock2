//! Now Playing ([first-party](../../.agents/product/plugins/first-party.md#now-playing)): the tile shows the
//! artwork, whether it plays and how far through it is; a click plays or pauses. The view has the track
//! and its controls; the commands put them in search.

use dock2_plugin::*;

#[derive(Default)]
struct NowPlaying {
    info: Option<NowPlayingInfo>,
    view: bool,
}

const VIEW: &str = "now-playing";

impl NowPlaying {
    fn tile(&self) -> Tile {
        let Some(info) = &self.info else {
            return Tile { image: Some(Icon::symbol("music.note")), label: "Nothing playing".into(), ..Default::default() };
        };
        let image = info.artwork.clone().map(Icon::png).unwrap_or_else(|| Icon::symbol(if info.playing { "music.note" } else { "pause.fill" }));
        Tile {
            image: Some(image),
            progress: progress(info),
            caption: (!info.playing).then(|| "Paused".to_string()),
            label: label(info),
            badge: None,
        }
    }

    fn detail(&self) -> Detail {
        let mut detail = Detail::new(VIEW);
        match &self.info {
            None => detail = detail.body("Nothing is playing."),
            Some(info) => {
                if let Some(artwork) = &info.artwork {
                    detail = detail.image(Icon::png(artwork.clone()));
                }
                let title = info.title.clone().unwrap_or_else(|| "Unknown".into());
                let by = [info.artist.clone(), info.album.clone()].into_iter().flatten().collect::<Vec<_>>().join(" — ");
                detail = detail.body(&format!("**{}**\n{}", escape(&title), escape(&by)));
                if let (Some(position), Some(duration)) = (info.position(now_ms()), info.duration.filter(|d| *d > 0.0)) {
                    detail = detail.scrubber(Scrubber {
                        id: "position".into(),
                        value: position.min(duration),
                        maximum: duration,
                        leading: Some(clock(position)),
                        trailing: Some(clock(duration)),
                    });
                }
                if let Some(app) = &info.app {
                    detail = detail.row("Playing in", app);
                }
            }
        }
        let playing = self.info.as_ref().is_some_and(|i| i.playing);
        detail.actions(vec![
            Action::new("toggle", if playing { "Pause" } else { "Play" }).icon(Icon::symbol(if playing { "pause.fill" } else { "play.fill" })),
            Action::new("next", "Next Track").icon(Icon::symbol("forward.fill")).key("cmd+shift+n"),
            Action::new("previous", "Previous Track").icon(Icon::symbol("backward.fill")).key("cmd+shift+b"),
            Action::new("forward", "Forward 15 Seconds").key("cmd+shift+f"),
            Action::new("back", "Back 15 Seconds").key("cmd+shift+r"),
        ])
    }

    fn redraw(&self, out: &mut Effects) {
        out.set_tile("player", self.tile());
        if self.view {
            out.update_view(self.detail());
        }
    }

    fn control(&self, action: &str, out: &mut Effects) {
        match action {
            "toggle" | "next" | "previous" => out.now_playing(action, None),
            "forward" | "back" => {
                if let Some(position) = self.info.as_ref().and_then(|i| i.position(now_ms())) {
                    let delta = if action == "forward" { 15.0 } else { -15.0 };
                    out.now_playing("seek", Some((position + delta).max(0.0)));
                }
            }
            _ => {}
        }
    }
}

impl Plugin for NowPlaying {
    fn handle(&mut self, event: Event, out: &mut Effects) {
        match event {
            Event::Started { .. } => {
                out.subscribe("nowPlaying");
                // The ring moves on while a track plays; twice a second is smooth enough at a tile's size.
                out.timer("tick", 2000, true);
                out.set_tile("player", self.tile());
            }
            Event::NowPlaying { info } => {
                self.info = info;
                self.redraw(out);
            }
            Event::Timer { .. } if self.info.as_ref().is_some_and(|i| i.playing) => self.redraw(out),
            Event::Tile { .. } => out.now_playing("toggle", None),
            Event::Command { id } if id == "show" => {
                self.view = true;
                out.show_view(self.detail());
            }
            Event::Command { id } => self.control(&id, out),
            Event::Action { action, .. } => self.control(&action, out),
            // The scrubber let go: there.
            Event::Submit { values, .. } => {
                if let Some(seconds) = values.get("position").and_then(|v| v.parse::<f64>().ok()) {
                    out.now_playing("seek", Some(seconds.max(0.0)));
                }
            }
            Event::ViewClosed { .. } => self.view = false,
            _ => {}
        }
    }
}

fn progress(info: &NowPlayingInfo) -> Option<f64> {
    let duration = info.duration.filter(|d| *d > 0.0)?;
    Some((info.position(now_ms())? / duration).clamp(0.0, 1.0))
}

fn label(info: &NowPlayingInfo) -> String {
    match (&info.title, &info.artist) {
        (Some(title), Some(artist)) => format!("{title} — {artist}"),
        (Some(title), None) => title.clone(),
        _ => "Now Playing".into(),
    }
}

fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    format!("{}:{:02}", total / 60, total % 60)
}

/// A track's name as text, not Markdown.
fn escape(text: &str) -> String {
    text.chars().flat_map(|c| if c.is_ascii_punctuation() { vec!['\\', c] } else { vec![c] }).collect()
}

export!(NowPlaying);
