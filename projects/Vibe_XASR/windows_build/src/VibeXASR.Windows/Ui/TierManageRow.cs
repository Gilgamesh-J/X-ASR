using System;
using System.Drawing;
using System.Windows.Forms;
using VibeXASR.Windows.Models;
using VibeXASR.Windows.Storage;

namespace VibeXASR.Windows.Ui;

/// <summary>
/// One row in the Model-management list (per tier): name + state on the left, an
/// action cluster on the right (Use / Download / Cancel / Delete) plus a live
/// progress bar while downloading. Mirrors the macOS <c>TierModelRow</c>.
/// <see cref="Refresh"/> is called on the Settings model-tab timer.
/// </summary>
internal sealed class TierManageRow : Panel
{
    private readonly ModelManager _mm;
    private readonly ModelTier _tier;

    private readonly VibeProgressBar _bar;
    private VibeButton? _primary;   // Use / Download / Cancel
    private VibeButton? _delete;    // Delete (when downloaded)
    private string _stateKey = "";

    public bool IsActive { get; set; }
    public ModelTier Tier => _tier;
    public event Action? UseRequested;

    private const string ApproxSize = "~615 MB";

    public TierManageRow(ModelManager mm, ModelTier tier, int width)
    {
        _mm = mm; _tier = tier;
        DoubleBuffered = true;
        BackColor = Theme.Surface;
        Width = width; Height = 58;

        _bar = new VibeProgressBar { Visible = false, Width = 180, Location = new Point(16, 36) };
        Controls.Add(_bar);
        Refresh();
    }

    public new void Refresh()
    {
        var progress = _mm.DownloadProgress(_tier);
        bool downloaded = _mm.IsTierDownloaded(_tier);
        bool failed = _mm.DidTierFail(_tier);
        string key = progress is { } p
            ? $"dl:{(int)(p * 100)}"
            : failed ? "failed" : downloaded ? $"have:{IsActive}" : "missing";

        if (progress is { } pf) { _bar.Visible = true; _bar.Fraction = pf; }
        else _bar.Visible = false;

        if (key != _stateKey)
        {
            _stateKey = key;
            RebuildButtons(progress is not null, downloaded, failed);
        }
        Invalidate();
        base.Refresh();
    }

    private void RebuildButtons(bool downloading, bool downloaded, bool failed)
    {
        if (_primary is not null) { Controls.Remove(_primary); _primary.Dispose(); _primary = null; }
        if (_delete is not null) { Controls.Remove(_delete); _delete.Dispose(); _delete = null; }

        if (downloading)
        {
            _primary = new VibeButton { Text = L10n.T("cancel"), Style = VibeButton.Kind.Ghost, Size = new Size(86, 30) };
            _primary.Click += (_, _) => _mm.CancelDownload(_tier);
        }
        else if (failed)
        {
            _primary = new VibeButton { Text = L10n.T("download"), Style = VibeButton.Kind.Solid, Size = new Size(100, 30) };
            _primary.Click += (_, _) => _mm.StartDownload(_tier);
        }
        else if (downloaded)
        {
            if (!IsActive)
            {
                _primary = new VibeButton { Text = L10n.T("model.use"), Style = VibeButton.Kind.Solid, Size = new Size(72, 30) };
                _primary.Click += (_, _) => UseRequested?.Invoke();
            }
            _delete = new VibeButton { Text = L10n.T("delete"), Style = VibeButton.Kind.Danger, Size = new Size(72, 30) };
            _delete.Click += (_, _) => _mm.DeleteTier(_tier);
        }
        else
        {
            _primary = new VibeButton { Text = L10n.T("download"), Style = VibeButton.Kind.Solid, Size = new Size(100, 30) };
            _primary.Click += (_, _) => _mm.StartDownload(_tier);
        }

        LayoutButtons();
    }

    private void LayoutButtons()
    {
        int x = Width - 16;
        if (_delete is not null) { x -= _delete.Width; _delete.Location = new Point(x, (Height - 30) / 2); Controls.Add(_delete); x -= 8; }
        if (_primary is not null) { x -= _primary.Width; _primary.Location = new Point(x, (Height - 30) / 2); Controls.Add(_primary); }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics; Draw.Hq(g);

        string title = L10n.T("model.tierRow", L10n.T($"model.tier.{(int)_tier}.name"));
        var titleFont = Theme.Ui(10f, FontStyle.Bold);
        var sz = TextRenderer.MeasureText(title, titleFont);
        TextRenderer.DrawText(g, title, titleFont, new Rectangle(16, 11, 260, titleFont.Height),
            Theme.Text, TextFormatFlags.Left | TextFormatFlags.NoPadding);

        if (IsActive)
        {
            int bx = 16 + sz.Width + 8;
            var badge = L10n.T("model.active");
            var bf = Theme.Mono(7.5f);
            int bw = TextRenderer.MeasureText(badge, bf).Width + 12;
            Draw.FillRounded(g, new RectangleF(bx, 11, bw, 16), 5, Theme.AccentSoft);
            TextRenderer.DrawText(g, badge, bf, new Rectangle(bx, 11, bw, 16), Theme.AccentB,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }

        if (!_bar.Visible)
        {
            var progress = _mm.DownloadProgress(_tier);
            bool downloaded = _mm.IsTierDownloaded(_tier);
            bool failed = _mm.DidTierFail(_tier);
            string state; Color color;
            if (failed) { state = L10n.T("model.dl.failed"); color = Theme.Error; }
            else if (downloaded) { state = L10n.T("model.downloaded"); color = Theme.Success; }
            else { state = L10n.T("model.notDownloaded"); color = Theme.TextMuted; }
            var mono = Theme.Mono(8.5f);
            TextRenderer.DrawText(g, ApproxSize + " · ", mono, new Rectangle(16, 33, 90, 18), Theme.TextMuted,
                TextFormatFlags.Left | TextFormatFlags.NoPadding);
            int sx = 16 + TextRenderer.MeasureText(ApproxSize + " · ", mono).Width;
            TextRenderer.DrawText(g, state, mono, new Rectangle(sx, 33, 200, 18), color,
                TextFormatFlags.Left | TextFormatFlags.NoPadding);
        }
        else
        {
            var progress = _mm.DownloadProgress(_tier) ?? 0;
            var mono = Theme.Mono(8.5f);
            string txt = progress > 0 ? L10n.T("model.downloading", (int)(progress * 100))
                                      : L10n.T("model.dl.starting");
            TextRenderer.DrawText(g, txt, mono, new Rectangle(16 + 188, 33, 160, 18), Theme.TextMuted,
                TextFormatFlags.Left | TextFormatFlags.NoPadding);
        }
    }
}
