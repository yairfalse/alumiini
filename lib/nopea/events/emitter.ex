defmodule Nopea.Events.Emitter do
  @moduledoc """
  GenServer for reliable CDEvents emission with queuing and retry.

  Events are queued and sent asynchronously via HTTP POST. Failed sends
  are retried with exponential backoff up to a configurable maximum.

  ## Configuration

  - `:endpoint` - HTTP endpoint URL (nil to disable)
  - `:http_client` - HTTP client tuple `{module, opts}` (default: Req-based)
  - `:retry_delay_ms` - Base retry delay in milliseconds (default: 1000)
  - `:max_retries` - Maximum retry attempts before dropping (default: 3)

  ## Example

      {:ok, pid} = Emitter.start_link(endpoint: "http://events.example.com/cdevents")

      event = Events.service_deployed("my-app", %{commit: "abc123"})
      Emitter.emit(pid, event)
  """

  use GenServer
  require Logger

  alias Nopea.Events

  defstruct [
    :endpoint,
    :http_client,
    :retry_delay_ms,
    :max_retries,
    enabled: true,
    queue: [],
    processing: false,
    dropped_count: 0,
    sent_count: 0
  ]

  @type t :: %__MODULE__{
          endpoint: String.t() | nil,
          http_client: {module(), keyword()} | nil,
          retry_delay_ms: pos_integer(),
          max_retries: non_neg_integer(),
          enabled: boolean(),
          queue: list(),
          processing: boolean(),
          dropped_count: non_neg_integer(),
          sent_count: non_neg_integer()
        }

  @default_retry_delay_ms 1000
  @default_max_retries 3

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Emit an event to the configured endpoint.

  Returns `:ok` immediately - actual sending happens asynchronously.
  """
  @spec emit(pid(), Events.t()) :: :ok
  def emit(pid, %Events{} = event) do
    GenServer.cast(pid, {:emit, event})
  end

  @doc """
  Get the current state of the emitter (for testing/debugging).
  """
  @spec get_state(pid()) :: t()
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    endpoint = Keyword.get(opts, :endpoint)
    enabled = endpoint != nil

    state = %__MODULE__{
      endpoint: endpoint,
      http_client: Keyword.get(opts, :http_client),
      retry_delay_ms: Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms),
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      enabled: enabled
    }

    if enabled do
      Logger.info("CDEvents emitter started, endpoint: #{endpoint}")
    else
      Logger.debug("CDEvents emitter disabled (no endpoint configured)")
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:emit, _event}, %{enabled: false} = state) do
    # Silently ignore when disabled
    {:noreply, state}
  end

  def handle_cast({:emit, event}, state) do
    # Add to queue with retry count
    queue_item = %{event: event, retry_count: 0}
    new_state = %{state | queue: state.queue ++ [queue_item]}

    # Start processing if not already
    new_state = maybe_start_processing(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:process_queue, %{queue: []} = state) do
    {:noreply, %{state | processing: false}}
  end

  def handle_info(:process_queue, %{queue: [item | rest]} = state) do
    case send_event(item.event, state) do
      :ok ->
        Logger.debug("CDEvent sent: #{item.event.type}")
        new_state = %{state | queue: rest, sent_count: state.sent_count + 1}
        schedule_next_process(new_state, 0)
        {:noreply, new_state}

      {:error, reason} ->
        new_retry_count = item.retry_count + 1

        if new_retry_count > state.max_retries do
          Logger.warning("CDEvent dropped after #{state.max_retries} retries: #{inspect(reason)}")
          new_state = %{state | queue: rest, dropped_count: state.dropped_count + 1}
          schedule_next_process(new_state, 0)
          {:noreply, new_state}
        else
          Logger.debug("CDEvent send failed, retry #{new_retry_count}: #{inspect(reason)}")
          updated_item = %{item | retry_count: new_retry_count}
          new_state = %{state | queue: [updated_item | rest]}
          delay = backoff_delay(new_retry_count, state.retry_delay_ms)
          schedule_next_process(new_state, delay)
          {:noreply, new_state}
        end
    end
  end

  # Private Functions

  defp maybe_start_processing(%{processing: true} = state), do: state

  defp maybe_start_processing(state) do
    send(self(), :process_queue)
    %{state | processing: true}
  end

  defp schedule_next_process(_state, delay) do
    Process.send_after(self(), :process_queue, delay)
  end

  defp backoff_delay(retry_count, base_delay) do
    # Exponential backoff: base * 2^(retry-1)
    trunc(base_delay * :math.pow(2, retry_count - 1))
  end

  defp send_event(event, state) do
    case Events.to_json(event) do
      {:ok, json} ->
        do_http_post(state.endpoint, json, state.http_client)

      {:error, reason} ->
        {:error, {:json_encode_failed, reason}}
    end
  end

  defp do_http_post(url, body, nil) do
    # Default: use Req
    case Req.post(url, body: body, headers: [{"content-type", "application/cloudevents+json"}]) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_http_post(url, body, {client_module, client_opts}) do
    # Pluggable client for testing
    headers = [{"content-type", "application/cloudevents+json"}]

    case client_module.post(url, body, headers, client_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
