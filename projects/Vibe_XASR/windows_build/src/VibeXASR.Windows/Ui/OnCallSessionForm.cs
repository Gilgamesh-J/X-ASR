using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// "本次候机记录" — the CURRENT OnCall session's transcript. This is EPHEMERAL and distinct
/// from the persistent History store: it accumulates the sentences recognized since the
/// current OnCall session started and is cleared when a new session begins. Faithful port of
/// the macOS <c>OnCallSessionView</c> (oldest-first list with timestamps, Copy-all + Export).
/// The overlay's "View" button opens THIS, not the global history.
/// </summary>
public sealed class OnCallSessionForm : Form
{
    private readonly Func<IReadOnlyList<HistoryEntry>> _provider;

    private Panel _header = null!;
    private Panel _listHost = null!;
    private Label _title = null!;
    private Label _count = null!;
    private VibeButton _copyBtn = null!;
    private VibeButton _exportBtn = null!;
    private int _builtWidth = -1;
    private int _builtCount = -1;

    public OnCallSessionForm(Func<IReadOnlyList<HistoryEntry>> provider)
    {
        _provider = provider;
        Text = L10n.T("oncall.session.title");
        ClientSize = new Size(460, 430);
        MinimumSize = new Size(360, 280);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Surface;
        Font = Theme.Ui(9.5f);
        Build();
        Reload();
    }

    private void Build()
    {
        _header = new Panel { BackColor = Theme.Surface2 };
        _title = new Label
        {
            Text = L10n.T("oncall.session.title"), Font = Theme.Ui(11f, FontStyle.Bold),
            ForeColor = Theme.Text, AutoSize = true, Location = new Point(16, 17), BackColor = Color.Transparent,
        };
        _count = new Label
        {
            Font = Theme.Mono(8.5f), ForeColor = Theme.TextMuted, AutoSize = true,
            Location = new Point(140, 20), BackColor = Color.Transparent,
        };
        _copyBtn = new VibeButton { Text = L10n.T("oncall.session.copyAll"), Style = VibeButton.Kind.Ghost, Size = new Size(96, 30) };
        _exportBtn = new VibeButton { Text = L10n.T("history.export"), Style = VibeButton.Kind.Ghost, Size = new Size(86, 30) };
        _copyBtn.Click += (_, _) => CopyAll();
        _exportBtn.Click += (_, _) => ExportAll();
        _header.Controls.AddRange(new Control[] { _title, _count, _copyBtn, _exportBtn });

        _listHost = new Panel { BackColor = Theme.Surface, AutoScroll = true };

        Controls.Add(_listHost);
        Controls.Add(_header);
        DoLayout();
    }

    protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); DoLayout(); }

    private void DoLayout()
    {
        if (_header is null || _listHost is null) return;
        int w = ClientSize.Width;
        _header.SetBounds(0, 0, w, 52);
        _listHost.SetBounds(0, 52, w, Math.Max(0, ClientSize.Height - 52));
        _count.Location = new Point(_title.Right + 10, 20);
        int x = w - 16;
        x -= _exportBtn.Width; _exportBtn.Location = new Point(x, 11); x -= 8;
        x -= _copyBtn.Width; _copyBtn.Location = new Point(x, 11);
        if (_listHost.ClientSize.Width != _builtWidth) RebuildRows();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyDarkTitleBar(Handle);
    }

    /// <summary>Refresh from the session snapshot (called on open + on each new utterance).</summary>
    public void Reload()
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke((Action)Reload); return; }
        var items = _provider();
        _count.Text = L10n.T("oncall.session.count", items.Count);
        _copyBtn.Visible = _exportBtn.Visible = items.Count > 0;
        _builtWidth = -1;   // force a row rebuild
        DoLayout();
    }

    private void RebuildRows()
    {
        if (_listHost is null) return;
        var items = _provider();
        _listHost.SuspendLayout();
        _listHost.Controls.Clear();
        if (items.Count == 0)
        {
            _listHost.Controls.Add(new Label
            {
                Text = "🛎\n\n" + L10n.T("oncall.session.empty"), Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleCenter, ForeColor = Theme.TextMuted,
                Font = Theme.Ui(11f), BackColor = Theme.Surface,
            });
        }
        else
        {
            int y = 0;
            int rowW = Math.Max(220, _listHost.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            // Oldest-first (chronological), like macOS.
            foreach (var item in items)
            {
                var row = new SessionRow(item, rowW) { Location = new Point(0, y) };
                _listHost.Controls.Add(row);
                y += row.Height;
            }
        }
        _listHost.ResumeLayout();
        _builtWidth = _listHost.ClientSize.Width;
        _builtCount = items.Count;
    }

    private string PlainText() =>
        string.Join(Environment.NewLine,
            _provider().Select(e => $"[{e.Timestamp.LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.CurrentCulture)}] {e.Text}"));

    private void CopyAll()
    {
        var s = PlainText();
        if (!string.IsNullOrEmpty(s)) { try { Clipboard.SetText(s); } catch { } }
    }

    private void ExportAll()
    {
        using var dlg = new SaveFileDialog
        {
            Title = L10n.T("oncall.session.title"),
            FileName = "vibe-oncall-session.txt",
            Filter = "Text (*.txt)|*.txt",
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        try { File.WriteAllText(dlg.FileName, PlainText(), new UTF8Encoding(true)); }
        catch (Exception ex) { MessageBox.Show(ex.Message); }
    }
}

/// <summary>One read-only OnCall session row: timestamp (muted) + wrapped recognized text.</summary>
internal sealed class SessionRow : Panel
{
    private readonly HistoryEntry _entry;

    public SessionRow(HistoryEntry entry, int width)
    {
        _entry = entry;
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        Width = width;
        int textW = width - 32;
        int textH = SettingsForm.MeasureWrapped(entry.Text, Theme.Mono(10.5f), textW);
        Height = 10 + 14 + 3 + textH + 11;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; Draw.Hq(g);
        var metaFont = Theme.Mono(8f);
        string ts = _entry.Timestamp.LocalDateTime.ToString("HH:mm:ss", CultureInfo.CurrentCulture);
        TextRenderer.DrawText(g, ts, metaFont, new Rectangle(16, 10, 200, 14), Theme.TextMuted,
            TextFormatFlags.Left | TextFormatFlags.NoPadding);

        var textFont = Theme.Mono(10.5f);
        int textW = Width - 32;
        int textH = SettingsForm.MeasureWrapped(_entry.Text, textFont, textW);
        TextRenderer.DrawText(g, _entry.Text, textFont, new Rectangle(16, 27, textW, textH), Theme.Text,
            TextFormatFlags.Left | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);

        using var pen = new Pen(Theme.Hairline);
        g.DrawLine(pen, 12, Height - 1, Width - 12, Height - 1);
    }
}
