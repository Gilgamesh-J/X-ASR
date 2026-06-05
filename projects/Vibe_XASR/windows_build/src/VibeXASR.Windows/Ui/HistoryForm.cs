using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// The History UI — a WinForms port of the macOS <c>HistoryView.swift</c>: header
/// (logo + title + count + Export + Clear all), a cumulative stats bar, the bilingual
/// privacy banner, and a newest-first list with per-row Copy / Edit / Delete revealed
/// on hover. Built as a reusable control so the standalone <see cref="HistoryForm"/>
/// and the Settings "Records" tab share one implementation.
/// </summary>
internal sealed class HistoryPanel : UserControl
{
    private readonly HistoryStore _store;

    private Panel _header = null!;
    private Panel? _stats;
    private Panel _privacy = null!;
    private Panel _listHost = null!;
    private VibeButton _exportBtn = null!;
    private VibeButton _clearBtn = null!;
    private Label _countLabel = null!;
    private int _builtWidth = -1;  // list width the current rows were laid out for

    private readonly System.Windows.Forms.Timer _tick = new() { Interval = 1000 }; // expiry countdowns

    public HistoryPanel(HistoryStore store)
    {
        _store = store;
        BackColor = Theme.Surface;
        DoubleBuffered = true;
        BuildChrome();
        _tick.Tick += (_, _) => RefreshExpiry();
        _tick.Start();
        Disposed += (_, _) => _tick.Dispose();
        L10n.LanguageChanged += Reload;
        Disposed += (_, _) => L10n.LanguageChanged -= Reload;
    }

    private void BuildChrome()
    {
        // Manual layout (no Dock) so header / stats / privacy / list stack deterministically.
        _header = new Panel { BackColor = Theme.Surface2 };
        var logo = new LogoTile { Bounds = new Rectangle(16, 15, 22, 22) };
        var title = new Label { Text = L10n.T("history.title"), Font = Theme.Ui(11f, FontStyle.Bold),
            ForeColor = Theme.Text, AutoSize = true, Location = new Point(46, 17), BackColor = Color.Transparent };
        _countLabel = new Label { Font = Theme.Mono(8.5f), ForeColor = Theme.TextMuted, AutoSize = true,
            Location = new Point(120, 19), BackColor = Color.Transparent };
        _exportBtn = new VibeButton { Text = L10n.T("history.export"), Style = VibeButton.Kind.Ghost, Size = new Size(86, 30) };
        _clearBtn = new VibeButton { Text = L10n.T("clear.all"), Style = VibeButton.Kind.Danger, Size = new Size(96, 30) };
        _exportBtn.Click += (_, _) => ExportVisible();
        _clearBtn.Click += (_, _) => ConfirmClear();
        _header.Controls.AddRange(new Control[] { logo, title, _countLabel, _exportBtn, _clearBtn });
        Controls.Add(_header);

        _privacy = new Panel { BackColor = SettingsForm.Blend(Theme.Success, Theme.Surface, 0.12f), Height = 44 };
        _privacy.Paint += PaintPrivacy;
        Controls.Add(_privacy);

        _listHost = new Panel { BackColor = Theme.Surface, AutoScroll = true };
        Controls.Add(_listHost);

        Reload();
    }

    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); DoLayout(); }

    /// <summary>Stack header → stats → privacy → list with explicit bounds.</summary>
    private void DoLayout()
    {
        if (_header is null || _privacy is null || _listHost is null) return;
        int w = ClientSize.Width, y = 0;
        _header.SetBounds(0, y, w, 52); y += 52;
        if (_stats is not null) { _stats.SetBounds(0, y, w, 34); y += 34; }
        _privacy.SetBounds(0, y, w, 44); y += 44;
        _listHost.SetBounds(0, y, w, Math.Max(0, ClientSize.Height - y));
        LayoutHeaderButtons();
        // Rows wrap to the list width, so rebuild them whenever that width changes
        // (notably: the first real size after the panel is shown / docked).
        if (_listHost.ClientSize.Width != _builtWidth) RebuildRows();
    }

    private void LayoutHeaderButtons()
    {
        int x = _header.Width - 16;
        x -= _clearBtn.Width; _clearBtn.Location = new Point(x, 11); x -= 8;
        x -= _exportBtn.Width; _exportBtn.Location = new Point(x, 11);
    }

    private void PaintPrivacy(object? sender, PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        TextRenderer.DrawText(g, "🔒", Theme.Ui(13f), new Rectangle(12, 0, 24, _privacy.Height),
            Theme.Success, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, "您的数据永远保存在本地,绝不上云", Theme.Ui(9.5f, FontStyle.Bold),
            new Rectangle(40, 6, _privacy.Width - 50, 18), Theme.Success,
            TextFormatFlags.Left | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, L10n.T("history.privacy"), Theme.Ui(8.5f),
            new Rectangle(40, 24, _privacy.Width - 50, 16), Theme.TextMuted,
            TextFormatFlags.Left | TextFormatFlags.NoPadding);
    }

    /// <summary>Rebuild stats bar + list from the store.</summary>
    public void Reload()
    {
        if (IsDisposed) return;
        var items = _store.List();

        _countLabel.Text = L10n.T("history.count", _store.List().Count);
        _exportBtn.Visible = _clearBtn.Visible = items.Count > 0;
        LayoutHeaderButtons();

        // Stats bar (created/destroyed depending on cumulative chars).
        if (_stats is not null) { Controls.Remove(_stats); _stats.Dispose(); _stats = null; }
        long chars = _store.LifetimeChars;
        if (chars > 0)
        {
            _stats = new Panel { BackColor = Theme.AccentSoft, Height = 34 };
            var text = StatsText(chars);
            _stats.Paint += (_, e) => TextRenderer.DrawText(e.Graphics, "📊  " + text, Theme.Ui(9.5f, FontStyle.Bold),
                new Rectangle(14, 0, _stats!.Width - 20, _stats.Height), Theme.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            Controls.Add(_stats);
        }

        _builtWidth = -1;   // force a row rebuild at the current width
        DoLayout();         // positions everything and (re)builds the rows
    }

    /// <summary>(Re)build the list rows for the current list width. Called by DoLayout when
    /// the list width changes (first show / resize) and after data mutations via Reload.</summary>
    private void RebuildRows()
    {
        if (_listHost is null) return;
        var items = _store.List();
        _listHost.SuspendLayout();
        _listHost.Controls.Clear();
        if (items.Count == 0)
        {
            var empty = new Label
            {
                Text = "🗒\n\n" + L10n.T("history.empty"), Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleCenter, ForeColor = Theme.TextMuted,
                Font = Theme.Ui(11f), BackColor = Theme.Surface,
            };
            _listHost.Controls.Add(empty);
        }
        else
        {
            int y = 0;
            int rowW = Math.Max(220, _listHost.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            foreach (var item in items)
            {
                var row = new HistoryRow(item, rowW) { Location = new Point(0, y) };
                row.CopyRequested += t => CopyText(t);
                row.DeleteRequested += id => { _store.Delete(id); Reload(); };
                row.UpdateRequested += (id, t) => { _store.Update(id, t); Reload(); };
                _listHost.Controls.Add(row);
                y += row.Height + 1;
            }
        }
        _listHost.ResumeLayout();
        _builtWidth = _listHost.ClientSize.Width;
    }

    private void RefreshExpiry()
    {
        bool any = false;
        foreach (Control c in _listHost.Controls)
            if (c is HistoryRow { HasExpiry: true } r) { r.Invalidate(); any = true; }
        // If an ephemeral row elapsed, a full reload drops it from the store.
        if (any && _store.List().Count != _listHost.Controls.OfType<HistoryRow>().Count())
            Reload();
    }

    private string StatsText(long chars)
    {
        double minutes = chars / 200.0;   // 200 chars/min typing speed
        double hours = minutes / 60.0;
        if (chars > 10_000 && hours > 100) return L10n.T("history.stats.big");
        string charsPart = L10n.T("history.stats.chars", chars.ToString("N0", CultureInfo.CurrentCulture));
        string timePart = hours >= 1
            ? L10n.T("history.stats.hours", hours.ToString("0.0"))
            : L10n.T("history.stats.minutes", minutes < 1 ? "<1" : ((int)minutes).ToString());
        return charsPart + timePart;
    }

    private void CopyText(string text)
    {
        try { Clipboard.SetText(text); } catch { }
    }

    private void ConfirmClear()
    {
        var r = MessageBox.Show(L10n.T("history.clear.confirm.body"), L10n.T("history.clear.confirm.title"),
            MessageBoxButtons.OKCancel, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
        if (r == DialogResult.OK) { _store.ClearAll(); Reload(); }
    }

    private void ExportVisible()
    {
        using var dlg = new SaveFileDialog
        {
            Title = L10n.T("history.export.panel"),
            FileName = "vibe-xasr-history.json",
            Filter = "JSON (*.json)|*.json|Text (*.txt)|*.txt",
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        var items = _store.List();
        bool isText = Path.GetExtension(dlg.FileName).Equals(".txt", StringComparison.OrdinalIgnoreCase);
        try
        {
            if (isText)
            {
                var sb = new StringBuilder();
                foreach (var e in items)
                    sb.Append(e.Timestamp.LocalDateTime.ToString("g", CultureInfo.CurrentCulture))
                      .Append('\n').Append(e.Text).Append("\n\n");
                File.WriteAllText(dlg.FileName, sb.ToString());
            }
            else
            {
                var arr = items.Select(e => new { date = e.Timestamp.ToString("o"), text = e.Text, mode = e.Mode });
                File.WriteAllText(dlg.FileName,
                    JsonSerializer.Serialize(arr, new JsonSerializerOptions { WriteIndented = true }));
            }
        }
        catch (Exception ex) { MessageBox.Show(ex.Message); }
    }
}

/// <summary>The standalone History window (hosts a <see cref="HistoryPanel"/>).</summary>
public sealed class HistoryForm : Form
{
    public HistoryForm(HistoryStore store)
    {
        Text = L10n.T("history.title");
        ClientSize = new Size(760, 640);   // wider for the v1.4.0 workspace (calendar + clustered rows)
        MinimumSize = new Size(520, 420);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Surface;
        Font = Theme.Ui(9.5f);
        Controls.Add(new HistoryWorkspacePanel(store) { Dock = DockStyle.Fill });
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyDarkTitleBar(Handle);
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Theme.ApplyDarkScrollbars(this);   // dark scrollbars to match the dark theme
    }
}

/// <summary>One history entry row: mono text + meta (timestamp · countdown · OnCall badge),
/// with Copy / Edit / Delete revealed on hover and inline editing.</summary>
internal sealed class HistoryRow : Panel
{
    private readonly HistoryEntry _entry;
    private readonly IconButton _copy, _edit, _del, _saveBtn;
    private TextBox? _editor;
    private const int ActionZone = 96;

    public bool HasExpiry => _entry.ExpiresAt is not null;
    public event Action<string>? CopyRequested;
    public event Action<Guid>? DeleteRequested;
    public event Action<Guid, string>? UpdateRequested;

    public HistoryRow(HistoryEntry entry, int width)
    {
        _entry = entry;
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        Width = width;

        int textW = width - 32 - ActionZone;
        int textH = SettingsForm.MeasureWrapped(entry.Text, Theme.Mono(10f), textW);
        Height = 11 + textH + 4 + 16 + 11;

        _copy = new IconButton("⧉") { Location = new Point(width - 16 - 26 * 3 - 8, 9) };
        _edit = new IconButton("✎") { Location = new Point(width - 16 - 26 * 2 - 4, 9) };
        _del = new IconButton("🗑", danger: true) { Location = new Point(width - 16 - 26, 9) };
        _saveBtn = new IconButton("✓") { Location = new Point(width - 16 - 26, 9), Visible = false };
        _copy.Click += (_, _) => CopyRequested?.Invoke(_entry.Text);
        _edit.Click += (_, _) => BeginEdit();
        _del.Click += (_, _) => DeleteRequested?.Invoke(_entry.Id);
        _saveBtn.Click += (_, _) => CommitEdit();
        foreach (var b in new[] { _copy, _edit, _del, _saveBtn }) { b.Visible = false; Controls.Add(b); }
    }

    protected override void OnMouseEnter(EventArgs e) { ShowActions(true); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e)
    {
        // Children also raise our MouseLeave; only hide when the cursor truly left the row.
        if (!RectangleToScreen(ClientRectangle).Contains(Cursor.Position)) ShowActions(false);
        base.OnMouseLeave(e);
    }

    private void ShowActions(bool on)
    {
        if (_editor is not null) return; // editing: keep the save button visible
        _copy.Visible = _edit.Visible = _del.Visible = on;
    }

    private void BeginEdit()
    {
        int textW = Width - 32 - ActionZone;
        _editor = new TextBox
        {
            Multiline = true, Text = _entry.Text, Font = Theme.Mono(10f),
            BackColor = Theme.Surface2, ForeColor = Theme.Text, BorderStyle = BorderStyle.FixedSingle,
            Location = new Point(16, 9), Size = new Size(textW, Height - 18),
        };
        _editor.KeyDown += (_, ev) =>
        {
            if (ev.KeyCode == Keys.Enter && !ev.Shift) { ev.SuppressKeyPress = true; CommitEdit(); }
            else if (ev.KeyCode == Keys.Escape) { CancelEdit(); }
        };
        Controls.Add(_editor);
        _editor.BringToFront();
        _editor.Focus();
        _copy.Visible = _edit.Visible = _del.Visible = false;
        _saveBtn.Visible = true;
        Invalidate();
    }

    private void CommitEdit()
    {
        if (_editor is null) return;
        var text = _editor.Text.Trim();
        var id = _entry.Id;
        EndEdit();
        if (!string.IsNullOrEmpty(text)) UpdateRequested?.Invoke(id, text);
    }

    private void CancelEdit() => EndEdit();

    private void EndEdit()
    {
        if (_editor is not null) { Controls.Remove(_editor); _editor.Dispose(); _editor = null; }
        _saveBtn.Visible = false;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (_editor is not null) return; // editor covers the text area
        var g = e.Graphics; Draw.Hq(g);
        int textW = Width - 32 - ActionZone;
        var textFont = Theme.Mono(10f);
        int textH = SettingsForm.MeasureWrapped(_entry.Text, textFont, textW);
        TextRenderer.DrawText(g, _entry.Text, textFont, new Rectangle(16, 11, textW, textH), Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);

        int my = 11 + textH + 4;
        var metaFont = Theme.Mono(8f);
        string ts = _entry.Timestamp.LocalDateTime.ToString("g", CultureInfo.CurrentCulture);
        TextRenderer.DrawText(g, ts, metaFont, new Rectangle(16, my, 200, 16), Theme.TextMuted,
            TextFormatFlags.Left | TextFormatFlags.NoPadding);
        int mx = 16 + TextRenderer.MeasureText(ts, metaFont).Width + 8;

        if (_entry.ExpiresAt is { } exp)
        {
            int remain = Math.Max(0, (int)Math.Ceiling((exp - DateTimeOffset.Now).TotalSeconds));
            TextRenderer.DrawText(g, $"⏳ {remain}s", metaFont, new Rectangle(mx, my, 70, 16), Theme.Error,
                TextFormatFlags.Left | TextFormatFlags.NoPadding);
            mx += 70;
        }
        if (_entry.Mode == "oncall")
        {
            var bf = Theme.Ui(7.5f, FontStyle.Bold);
            int bw = TextRenderer.MeasureText("OnCall", bf).Width + 12;
            Draw.FillRounded(g, new RectangleF(mx, my - 1, bw, 16), 8, Color.FromArgb(41, Theme.AccentB));
            TextRenderer.DrawText(g, "OnCall", bf, new Rectangle(mx, my - 1, bw, 16), Theme.AccentB,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}

/// <summary>Small icon button used by history rows (hover-highlighted).</summary>
internal sealed class IconButton : Control
{
    private readonly string _glyph;
    private readonly bool _danger;
    private bool _hover;

    public IconButton(string glyph, bool danger = false)
    {
        _glyph = glyph; _danger = danger;
        DoubleBuffered = true; Cursor = Cursors.Hand;
        Size = new Size(26, 24);
        Font = Theme.Ui(9.5f);
        SetStyle(ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        if (_hover) Draw.FillRounded(g, new RectangleF(0, 0, Width, Height), 6, Theme.Surface2);
        var color = _hover ? (_danger ? Theme.Error : Theme.AccentB) : Theme.TextMuted;
        TextRenderer.DrawText(g, _glyph, Font, new Rectangle(0, 0, Width, Height), color,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}
