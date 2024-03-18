defmodule LivePhone do
  @external_resource "./README.md"
  @moduledoc """
  #{File.read!(@external_resource)}
  """

  use Phoenix.LiveComponent
  use Phoenix.HTML

  alias Phoenix.LiveView.Socket
  alias LivePhone.{Country, Util}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign_new(:preferred, fn -> ["US", "GB"] end)
     |> assign_new(:tabindex, fn -> 0 end)
     |> assign_new(:apply_format?, fn -> false end)
     |> assign_new(:value, fn -> "" end)
     |> assign_new(:opened?, fn -> false end)
     |> assign_new(:valid?, fn -> false end)
     |> assign_new(:get_name_fn, fn -> & &1.name end)
     |> assign_new(:debounce_on_blur?, fn -> false end)
     |> assign_new(:dirty?, fn -> false end)
     |> assign_new(:country_search_term, fn -> "" end)}
  end

  @impl true
  def update(assigns, socket) do
    current_country =
      assigns[:country] || socket.assigns[:country] || hd(assigns[:preferred] || ["US"])

    masks =
      if assigns[:apply_format?] do
        current_country
        |> get_masks()
        |> Enum.join(",")
      end

    socket =
      socket
      |> assign(assigns)
      |> assign_country(current_country)
      |> assign(:masks, masks)

    {:ok, set_value(socket, socket.assigns.value)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class={"live_phone #{if @valid?, do: "live_phone-valid"}"}
      id={"live_phone-#{@id}"}
      phx-hook="LivePhone"
    >
      <.country_selector
        tabindex={@tabindex}
        target={@myself}
        opened?={@opened?}
        country={@country}
        wrapper={"live_phone-#{@id}"}
      />

      <input
        type="tel"
        class="live_phone-input"
        value={assigns[:value]}
        tabindex={assigns[:tabindex]}
        placeholder={assigns[:placeholder] || get_placeholder(assigns[:country])}
        data-masks={@masks}
        phx-target={@myself}
        phx-keyup="typing"
        phx-blur="close"
      />

      <%= hidden_input(
        assigns[:form],
        assigns[:field],
        name: assigns[:name] || input_name(assigns[:form], assigns[:field]),
        value: assigns[:formatted_value]
      ) %>

      <%= if @opened? do %>
        <.country_list
          country={@country}
          country_search_placeholder={assigns[:country_search_placeholder]}
          country_search_term={assigns[:country_search_term]}
          preferred={@preferred}
          get_name_fn={@get_name_fn}
          id={@id}
          target={@myself} />
      <% end %>
    </div>
    """
  end

  defguardp is_empty(value) when is_nil(value) or value == ""

  @spec set_value(Socket.t(), String.t(), list()) :: Socket.t()
  def set_value(socket, value, opts \\ []) do
    {country, value} =
      case value do
        empty when is_empty(empty) and not socket.assigns.dirty? ->
          case socket.assigns do
            %{form: form, field: field} when not is_nil(form) and not is_nil(field) ->
              value = input_value(form, field)

              {get_country_code(value) || socket.assigns[:country], value || ""}

            %{value: assigns_value} when not is_nil(assigns_value) ->
              {socket.assigns[:country], value || ""}

            _ ->
              {socket.assigns[:country], value || ""}
          end

        found_value ->
              {socket.assigns[:country], found_value || ""}
      end

    {_, formatted_value} = Util.normalize(value, country)
    value = apply_mask(value, country)
    valid? = Util.valid?(formatted_value)

    push? = (socket.assigns[:formatted_value] || "") != formatted_value && !Keyword.get(opts, :only_value?, false)

    socket
    |> assign(:valid?, valid?)
    |> assign(:country, country)
    |> assign(:value, value)
    |> assign(:dirty?, socket.assigns.dirty? || (socket.assigns[:formatted_value] || "") != formatted_value)
    |> then(fn socket ->
      if Keyword.get(opts, :only_value?, false) do
        socket
      else
        socket |> assign(:formatted_value, formatted_value)
      end
    end)
    |> then(fn socket ->
      if push? do
        push_event(socket, "change", %{
          id: "live_phone-#{socket.assigns.id}",
          value: formatted_value
        })
      else
        socket
      end
    end)
  end

  defp get_country_code(value) do
    case Util.get_country(value) do
      {:ok, %{code: code}} -> code
      _ -> nil
    end
  end

  defp apply_mask(value, _country) when is_empty(value), do: value

  defp apply_mask(value, country) do
    case ExPhoneNumber.parse(value, country) do
      {:ok, phone_number} ->
        ExPhoneNumber.Model.PhoneNumber.get_national_significant_number(phone_number)

      _ ->
        ""
    end
  end

  @impl true
  def handle_event("typing", %{"value" => value}, socket) do
    only_value? = socket.assigns.debounce_on_blur? || false

    {:noreply, set_value(socket, value, only_value?: only_value?)}
  end

  def handle_event("select_country", %{"country" => country}, socket) do
    valid? = Util.valid?(socket.assigns[:formatted_value])

    placeholder =
      if socket.assigns[:country] == country do
        socket.assigns[:placeholder]
      else
        get_placeholder(country)
      end

    socket =
      socket
      |> assign_country(country)
      |> assign(:valid?, valid?)
      |> assign(:opened?, false)
      |> assign(:placeholder, placeholder)
      |> push_event("focus", %{id: "live_phone-#{socket.assigns.id}"})

    value = socket.assigns.value
    if value && value != "" do
      {:noreply, set_value(socket, value)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle", _, socket) do
    {:noreply,
     socket
     |> assign(:opened?, socket.assigns.opened? != true)
     |> then(fn socket ->
       if socket.assigns.opened? != true do
         socket
       else
         push_event(socket, "countrysearchfocus", %{})
       end
     end)}
  end

  def handle_event("close", params, socket) do
    socket = if socket.assigns.debounce_on_blur? && params["value"] do
      set_value(socket, params["value"])
    else
      socket
    end

    {:noreply, assign(socket, :opened?, false)}
  end

  def handle_event("search-country", %{"value" => value}, socket) do
    {:noreply, assign(socket, :country_search_term, value)}
  end

  @spec get_placeholder(String.t()) :: String.t()
  defp get_placeholder(country) do
    country
    |> ExPhoneNumber.Metadata.get_for_region_code()
    |> case do
      %{country_code: country_code, fixed_line: %{example_number: number}} ->
        number
        |> String.replace(~r/\d/, "5")
        |> ExPhoneNumber.parse(country)
        |> case do
          {:ok, result} ->
            result
            |> ExPhoneNumber.format(:international)
            |> String.replace(~r/^(\+|00)#{country_code}/, "")
            |> String.trim()

          _ ->
            ""
        end
    end
  end

  @spec get_masks(String.t()) :: [String.t()]
  defp get_masks(country) do
    metadata = ExPhoneNumber.Metadata.get_for_region_code(country)

    # Iterate through all metadata to find phone number descriptions
    # with example numbers only, and return those example numbers
    metadata
    |> Map.from_struct()
    |> Enum.map(fn
      {_, %ExPhoneNumber.Metadata.PhoneNumberDescription{} = desc} -> desc.example_number
      _other -> nil
    end)
    |> Enum.filter(& &1)

    # Parse all example numbers with the country and only keep valid ones
    |> Enum.map(&ExPhoneNumber.parse(&1, country))
    |> Enum.map(fn
      {:ok, parsed} -> parsed
      _other -> nil
    end)
    |> Enum.filter(& &1)

    # Format all parsed numbers with the international format
    # but removing the leading country_code. Transform all digits to X
    # to be used for a mask
    |> Enum.map(&ExPhoneNumber.format(&1, :international))
    |> Enum.map(&String.replace(&1, ~r/^(\+|00)#{metadata.country_code}/, ""))
    |> Enum.map(&String.replace(&1, ~r/\d/, "X"))
    |> Enum.map(&String.trim/1)

    # And make sure we only have unique ones
    |> Enum.uniq()
  end

  @spec assign_country(Socket.t(), Country.t() | String.t()) :: Socket.t()
  defp assign_country(socket, %Country{code: country}), do: assign_country(socket, country)
  defp assign_country(socket, country), do: assign(socket, :country, country)

  defp country_selector(assigns) do
    region_code =
      case ExPhoneNumber.Metadata.get_for_region_code(assigns[:country]) do
        nil -> ""
        code -> "+#{code.country_code}"
      end

    assigns = assign(assigns, :region_code, region_code)

    ~H"""
    <div
      class="live_phone-country"
      tabindex={@tabindex}
      phx-target={@target}
      phx-click="toggle"
      aria-owns={@wrapper}
      aria-expanded={to_string(@opened?)}
      role="combobox"
    >
      <span class="live_phone-country-flag"><%= Util.emoji_for_country(@country) %></span>
      <span class="live_phone-country-code"><%= @region_code %></span>
    </div>
    """
  end

  defp country_list(assigns) do
    assigns =
      if assigns[:country] do
        assign(assigns, :preferred, [assigns[:country] | assigns[:preferred]])
      else
        assigns
      end

    assigns = assign_new(assigns, :countries, fn -> Country.list(assigns[:preferred]) end)

    assigns =
      assign_new(assigns, :last_preferred, fn ->
        assigns[:countries]
        |> Enum.filter(& &1.preferred)
        |> List.last()
      end)

    ~H"""
    <ul class="live_phone-country-list" id={"live_phone-country-list-#{@id}"} role="listbox">
      <input
        id={"live_phone-country-search-#{@id}"}
        type="text"
        class="live_phone-country-search-input"
        value={assigns[:country_search_term]}
        placeholder={assigns[:country_search_placeholder]}
        phx-target={@target}
        phx-keyup="search-country"
        autocomplete="off"
      />

      <%= for country <- filter_countries(@countries, assigns[:country_search_term], @get_name_fn) do %>
        <.country_list_item country={country} current_country={@country} get_name_fn={@get_name_fn} target={@target} />

        <%= if country == @last_preferred do %>
          <li aria-disabled="true" class="live_phone-country-separator" role="separator"></li>
        <% end %>
      <% end %>
    </ul>
    """
  end

  defp filter_countries(countries, nil, _), do: countries
  defp filter_countries(countries, "", _), do: countries

  defp filter_countries(countries, term, get_name_fn) do
    term = term |> String.downcase() |> String.replace_prefix("+", "")
    IO.inspect(hd(countries))

    Enum.filter(countries, fn country ->
      String.contains?(String.downcase(country.name), term) ||
        String.contains?(String.downcase(country.code), term) ||
        String.contains?(String.downcase(country.region_code), term) ||
        String.contains?(String.downcase(get_name_fn.(country)), term)
    end)
  end

  defp country_list_item(assigns) do
    selected? = assigns[:country].code == assigns[:current_country]
    assigns = assign(assigns, :selected?, selected?)

    class = ["live_phone-country-item"]
    class = if assigns[:selected?], do: ["selected" | class], else: class
    class = if assigns[:country].preferred, do: ["preferred" | class], else: class

    assigns = assign(assigns, :class, class)

    ~H"""
    <li
      aria-selected={to_string(@selected?)}
      class={@class}
      phx-click="select_country"
      phx-target={@target}
      phx-value-country={@country.code}
      role="option"
    >
      <span class="live_phone-country-item-flag"><%= @country.flag_emoji %></span>
      <span class="live_phone-country-item-name"><%= @get_name_fn.(@country) %></span>
      <span class="live_phone-country-item-code">+<%= @country.region_code %></span>
    </li>
    """
  end
end
