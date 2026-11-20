using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
// The project compiles with both WPF and WinForms implicit usings, so these three names collide.
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using TextBox = System.Windows.Controls.TextBox;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using TextChangedEventArgs = System.Windows.Controls.TextChangedEventArgs;

namespace VibeXASR.Windows.Ui.Wpf;

/// <summary>
/// A ComboBox whose drop-down carries its own filter field (template part <c>PART_SearchBox</c>).
/// The provider list is 23 built-ins + custom entries + the 自定义… row: scrollable since the ScrollViewer
/// fix, but still several screens long, so typing two letters has to be faster than scrolling.
///
/// The filter uses <c>Items.Filter</c>, which means it only works with the items added directly to Items
/// (that is what <see cref="SettingsWindow"/> does; nothing here sets ItemsSource).
/// </summary>
public sealed class SelectBox : ComboBox
{
    /// <summary>Lists shorter than this keep the plain drop-down — a 3-option picker does not need a search box.</summary>
    public const int MinItemsForSearch = 8;

    /// <summary>Read by the template to show/hide the filter row (false for a plain ComboBox).</summary>
    public static readonly DependencyProperty ShowSearchProperty = DependencyProperty.RegisterAttached(
        "ShowSearch", typeof(bool), typeof(SelectBox), new PropertyMetadata(false));

    public static bool GetShowSearch(DependencyObject o) => (bool)o.GetValue(ShowSearchProperty);
    public static void SetShowSearch(DependencyObject o, bool value) => o.SetValue(ShowSearchProperty, value);

    private TextBox? _search;
    private object? _selectedBeforeFilter;

    public SelectBox()
    {
        // Typing belongs to the filter box, not to the ComboBox's type-ahead.
        IsTextSearchEnabled = false;
        Loaded += (_, _) => RefreshSearchVisibility();
    }

    public override void OnApplyTemplate()
    {
        if (_search is not null)
        {
            _search.TextChanged -= OnSearchTextChanged;
            _search.PreviewKeyDown -= OnSearchKeyDown;
        }
        base.OnApplyTemplate();
        _search = GetTemplateChild("PART_SearchBox") as TextBox;
        if (_search is not null)
        {
            _search.TextChanged += OnSearchTextChanged;
            _search.PreviewKeyDown += OnSearchKeyDown;
        }
        RefreshSearchVisibility();
    }

    /// <summary>
    /// Decide whether this list is long enough for a filter field. Deliberately NOT re-evaluated while a
    /// filter is active: Items.Count reports the FILTERED view, so listening to it would hide the very box
    /// the user is typing in as soon as the list narrowed to a few rows.
    /// </summary>
    private void RefreshSearchVisibility()
        => SetValue(ShowSearchProperty, Items.Count >= MinItemsForSearch);

    /// <summary>Dev hook: type into the field the way a user would (TextChanged drives the filter), falling
    /// back to applying it directly when the popup has not been templated yet.</summary>
    public void SimulateTyping(string? text)
    {
        if (_search is not null) _search.Text = text ?? "";
        else ApplyFilter(text);
    }

    /// <summary>Public entry point: filter as if the user typed <paramref name="query"/>.</summary>
    public void ApplyFilter(string? query)
    {
        query = (query ?? "").Trim();
        if (query.Length == 0)
        {
            Items.Filter = null;
            if (_selectedBeforeFilter is object sel && Items.Contains(sel)) SelectedItem = sel;
            _selectedBeforeFilter = null;
            return;
        }
        _selectedBeforeFilter ??= SelectedItem;
        var q = query.ToLowerInvariant();
        Items.Filter = o => o is ComboBoxItem item
                         && (item.Content?.ToString() ?? "").ToLowerInvariant().Contains(q, StringComparison.Ordinal);
        // No auto-selection while typing: every selection change would fire the owner's onChange handler
        // (which re-applies settings). Enter picks the first match instead.
    }

    private void OnSearchTextChanged(object? sender, TextChangedEventArgs e)
        => ApplyFilter(_search?.Text);

    private void OnSearchKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            if (Items.Count > 0 && Items[0] is ComboBoxItem first) { SelectedItem = first; IsDropDownOpen = false; }
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            IsDropDownOpen = false;
            e.Handled = true;
        }
        else if (e.Key == Key.Down && Items.Count > 0)
        {
            // Hand the keyboard to the list so ↑/↓/Enter work as usual after filtering.
            MoveFocus(new TraversalRequest(FocusNavigationDirection.Down));
            e.Handled = true;
        }
    }

    protected override void OnDropDownOpened(EventArgs e)
    {
        base.OnDropDownOpened(e);
        RefreshSearchVisibility();                          // count BEFORE filtering decides the row
        if (_search is null || !GetShowSearch(this)) return;
        _search.Text = "";                                  // every open starts unfiltered
        ApplyFilter("");
        Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => _search.Focus()));
    }

    protected override void OnDropDownClosed(EventArgs e)
    {
        base.OnDropDownClosed(e);
        if (_search is not null && _search.Text.Length > 0) _search.Text = "";
        ApplyFilter("");                                     // restore the pre-filter selection
    }
}
