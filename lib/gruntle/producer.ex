defmodule Gruntle.KafkaExGenStageConsumer do
  @moduledoc """
  A KafkaEx GenConsumer implementation in a GenStage producer.

  A `KafkaExGenStageConsumer`is a `GenStage` producer implementation of a
  `KafkaEx.GenConsumer`. Unlike a GenConsumer, a `KafkaExGenStageConsumer`
  consumes events from kafka in response to demand from subscribing services.
  Allowing controlled consumption according to available service capacity.


  ## Consumer Group Supervision

  `KafkaExGenStageConsumer` should be started as a `KafkaEx.GenConsumer` would
  be started, except with an additional argument for the subscribing module

  > n.b. This may not be the most ideal pattern, suggestions of alternate
  supervision approaches are welcome.

  ```elixir
   defmodule MyApp do
    use Application

    def start(_type, _args) do
      import Supervisor.Spec

      consumer_group_opts = [
        # setting for the ConsumerGroup
        heartbeat_interval: 1_000,
        # this setting will be forwarded to the GenConsumer
        commit_interval: 1_000,
        extra_consumer_args: [],
        commit_strategy: :async_commit
      ]

      subscriber_impl = ExampleSubscriber
      consumer_group_name = "example_group"
      topic_names = ["example_topic"]

      children = [
        # ... other children
        supervisor(
          KafkaEx.ConsumerGroup,
          [KafkaExGenStageConsumer, subscriber_impl, consumer_group_name, topic_names, consumer_group_opts]
        )
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end
  end
  ```

  The subscribing module is expected to implement a single function of
  `start_link/1`, which receives a tuple of `{pid, topic, partition, extra_consumer_args}`.


  ## Example Consumer stage

  ```elixir
  defmodule ExampleSubscriber do
    use GenStage

    def start_link({pid, topic, partition, extra_consumer_args} = opts) do
      {gen_server_options, _} = Keyword.split(extra_consumer_args, [:name, :debug]) # GenServer.Options.t()
      GenStage.start_link(__MODULE__, opts, gen_server_options)
    end

    def init({pid, topic, partition, extra_consumer_args} = opts) do
      {:consumer, [], subscribe_to: [pid]}
    end

    def handle_events(events, state) do
      events
      |> Enum.map(&do_work/1)

      {:noreply, [], state}
    end
  end
  ```

  ## Example `Flow` usage

  ```elixir
  defmodule ExampleFlowConsumer do
    def start_link({pid, topic, partition, extra_consumer_args} = opts) do

      Flow.from_stages([pid])
      |> Flow.map(&decode_event/1)
      |> Flow.map(&do_work/1)
      |> Flow.map(&KafkaExGenStageConsumer.trigger_commit(pid, {:async_commit, &1.offset}))
      |> Flow.start_link()

    end
  end
  ```

  ## Controlling Offset Commits

  Because the Consumer Subscriber Stage is started by the Consumer, its possible
  to lose events in the event of a crash or a consumer group reballance.

  There are two strategies to handle this case:

  1. use your consumer subscriber stage as a relay to consumers outside of the
  `ConsumerGroup` supervision tree
  2. use `commit_strategy: :no_commit` and add a commit offset stage to your
  genstage pipeline. Call `KafkaExGenStageConsumer.trigger_commit/2` to trigger
  commits
  """

  use GenStage

  require Logger

  alias KafkaEx.Protocol.Fetch.Message
  alias KafkaEx.Protocol.Fetch.Response, as: FetchResponse
  alias KafkaEx.Protocol.Offset.Response, as: OffsetResponse
  alias KafkaEx.Protocol.OffsetCommit.Request, as: OffsetCommitRequest
  alias KafkaEx.Protocol.OffsetCommit.Response, as: OffsetCommitResponse
  alias KafkaEx.Protocol.OffsetFetch.Request, as: OffsetFetchRequest
  alias KafkaEx.Protocol.OffsetFetch.Response, as: OffsetFetchResponse

  @typedoc """
  Option values used when starting a `KafkaEx.GenConsumer`.
  """
  @type option ::
          {:commit_interval, non_neg_integer}
          | {:commit_threshold, non_neg_integer}
          | {:auto_offset_reset, :none | :earliest | :latest}
          | {:extra_consumer_args, map()}

  @typedoc """
  Options used when starting a `KafkaEx.GenConsumer`.
  """
  @type options :: [option | GenServer.option()]

  defmodule State do
    @moduledoc false
    defstruct [
      :commit_interval,
      :commit_threshold,
      :worker_name,
      :group,
      :topic,
      :partition,
      :current_offset,
      :committed_offset,
      :acked_offset,
      :last_commit,
      :auto_offset_reset,
      :fetch_options,
      :commit_strategy,
      :demand
    ]
  end

  @commit_interval 5_000
  @commit_threshold 100
  @auto_offset_reset :none

  @producer_options []
  @commit_strategy :async_commit

  @spec start_link(
          subscribing_modules :: module,
          consumer_group_name :: binary,
          topic_name :: binary,
          partition_id :: non_neg_integer,
          options
        ) :: GenServer.on_start()

  def start_link(subscribing_module, group_name, topic, partition, opts \\ []) do
    {server_opts, consumer_opts} = Keyword.split(opts, [:debug, :name, :timeout, :spawn_opt])

    GenStage.start_link(
      __MODULE__,
      {subscribing_module, group_name, topic, partition, consumer_opts},
      server_opts
    )
  end

  def init({subscribing_module, group_name, topic, partition, opts}) do
    producer_options =
      Keyword.get(
        opts,
        :producer_options,
        Application.get_env(:kaufmann_ex, :producer_options, @producer_options)
      )

    commit_interval =
      Keyword.get(
        opts,
        :commit_interval,
        Application.get_env(:kafka_ex, :commit_interval, @commit_interval)
      )

    commit_threshold =
      Keyword.get(
        opts,
        :commit_threshold,
        Application.get_env(:kafka_ex, :commit_threshold, @commit_threshold)
      )

    auto_offset_reset =
      Keyword.get(
        opts,
        :auto_offset_reset,
        Application.get_env(:kafka_ex, :auto_offset_reset, @auto_offset_reset)
      )

    commit_strategy =
      Keyword.get(
        opts,
        :commit_strategy,
        Application.get_env(:kafka_ex, :commit_strategy, @commit_strategy)
      )

    extra_consumer_args =
      Keyword.get(
        opts,
        :extra_consumer_args
      )

    worker_opts = Keyword.take(opts, [:uris])

    {:ok, worker_name} =
      KafkaEx.create_worker(
        :no_name,
        [consumer_group: group_name] ++ worker_opts
      )

    default_fetch_options = [
      auto_commit: false,
      worker_name: worker_name
    ]

    given_fetch_options = Keyword.get(opts, :fetch_options, [])
    fetch_options = Keyword.merge(default_fetch_options, given_fetch_options)

    state = %State{
      commit_interval: commit_interval,
      commit_threshold: commit_threshold,
      auto_offset_reset: auto_offset_reset,
      worker_name: worker_name,
      group: group_name,
      topic: topic,
      partition: partition,
      fetch_options: fetch_options,
      commit_strategy: commit_strategy
    }

    # Not sure the best way to start a child of a worker module that needs to
    # be started with the PID of self
    {:ok, _pid} = subscribing_module.start_link({self, topic, partition, extra_consumer_args})

    Process.flag(:trap_exit, true)

    {:producer, state, producer_options}
  end

  @spec handle_demand(integer, KafkaExGenStageConsumer.State.t()) ::
          {:noreply, [MEssage.t()], KafkaExGenStageConsumer.State.t()}
  def handle_demand(
        demand,
        %State{current_offset: nil, last_commit: nil} = state
      ) do
    new_state = %State{
      load_offsets(state)
      | last_commit: :erlang.monotonic_time(:milli_seconds),
        demand: demand
    }

    {:noreply, [], new_state}
  end

  def handle_demand(demand, state)
      when demand > 0 do
    Process.send_after(self(), :try_to_meet_demand, 5)

    {:noreply, [], %State{state | demand: demand}}
  end

  def handle_demand(0, state) do
    {:noreply, [], state}
  end

  @spec do_handle_demand(KafkaExGenStageConsumer.State.t()) ::
          {:noreply, [any()], KafkaExGenStageConsumer.State.t()}
  defp do_handle_demand(
         %State{
           topic: topic,
           partition: partition,
           current_offset: offset,
           fetch_options: fetch_options,
           demand: demand
         } = state
       ) do
    # Logger.debug("Handling demand #{demand} on #{topic}/#{partition}")

    [
      %FetchResponse{
        topic: ^topic,
        partitions: [
          %{error_code: error_code, partition: ^partition, message_set: message_set}
        ]
      }
    ] =
      KafkaEx.fetch(
        topic,
        partition,
        Keyword.merge(fetch_options, offset: offset)
      )

    state =
      case error_code do
        :offset_out_of_range ->
          handle_offset_out_of_range(state)

        :no_error ->
          state
      end

    [state, commit_strategy] =
      case List.last(message_set) do
        nil ->
          [state, :async_commit]

        %Message{offset: nil} ->
          [state, :async_commit]

        %Message{offset: last_offset} ->
          [
            %State{
              state
              | acked_offset: last_offset + 1,
                current_offset: last_offset + 1,
                demand: demand - length(message_set)
            },
            state.commit_strategy
          ]
      end

    Process.send_after(self(), :try_to_meet_demand, 10)

    # Todo allow more flexible commit_strategy
    {:noreply, message_set, handle_commit(commit_strategy, state)}
  end

  @doc """
  Returns the topic and partition id for this consumer process
  """
  @spec partition(GenStage.stage()) ::
          {topic :: binary, partition_id :: non_neg_integer}
  def partition(gen_consumer) do
    GenStage.call(gen_consumer, :partition)
  end

  def trigger_commit(gen_consumer, {strategy, offset}) do
    GenStage.cast(gen_consumer, {:commit, strategy, offset})
  end

  def handle_call(:partition, _from, state) do
    {:reply, {state.topic, state.partition}, [], state}
  end

  def handle_cast({:commit, strategy, offset}, %State{acked_offset: acked_offset} = state)
      when offset > acked_offset do
    {:noreply, [], handle_commit(strategy, %State{state | acked_offset: offset})}
  end

  def handle_cast({:commit, _, _}, state) do
    {:noreply, [], state}
  end

  # handle_info maintains the loop attemting to meet demand until demand 0
  def handle_info(:try_to_meet_demand, %{demand: demand} = state) when demand > 0 do
    do_handle_demand(state)
  end

  def handle_info(:try_to_meet_demand, state) do
    {:noreply, [], state}
  end

  def terminate(_reason, %State{} = state) do
    commit(state)
    Process.unlink(state.worker_name)
    KafkaEx.stop_worker(state.worker_name)
  end

  # Helpers

  defp handle_offset_out_of_range(
         %State{
           worker_name: worker_name,
           topic: topic,
           partition: partition,
           auto_offset_reset: auto_offset_reset
         } = state
       ) do
    [
      %OffsetResponse{
        topic: ^topic,
        partition_offsets: [
          %{partition: ^partition, error_code: :no_error, offset: [offset]}
        ]
      }
    ] =
      case auto_offset_reset do
        :earliest ->
          KafkaEx.earliest_offset(topic, partition, worker_name)

        :latest ->
          KafkaEx.latest_offset(topic, partition, worker_name)

        _ ->
          Logger.warn(
            "Offset out of range while consuming topic #{topic}, partition #{partition}."
          )

          raise "Offset out of range while consuming topic #{topic}, partition #{partition}."
      end

    %State{
      state
      | current_offset: offset,
        committed_offset: offset,
        acked_offset: offset
    }
  end

  defp handle_commit(:no_commit, %State{} = state), do: state
  defp handle_commit(:sync_commit, %State{} = state), do: commit(state)

  defp handle_commit(
         :async_commit,
         %State{
           acked_offset: acked,
           committed_offset: committed,
           commit_threshold: threshold,
           last_commit: last_commit,
           commit_interval: interval
         } = state
       ) do
    case acked - committed do
      0 ->
        %State{state | last_commit: :erlang.monotonic_time(:milli_seconds)}

      n when n >= threshold ->
        commit(state)

      _ ->
        if :erlang.monotonic_time(:milli_seconds) - last_commit >= interval do
          commit(state)
        else
          state
        end
    end
  end

  defp commit(%State{acked_offset: offset, committed_offset: offset} = state) do
    state
  end

  defp commit(
         %State{
           worker_name: worker_name,
           group: group,
           topic: topic,
           partition: partition,
           acked_offset: offset
         } = state
       ) do
    request = %OffsetCommitRequest{
      consumer_group: group,
      topic: topic,
      partition: partition,
      offset: offset
    }

    [%OffsetCommitResponse{topic: ^topic, partitions: [^partition]}] =
      KafkaEx.offset_commit(worker_name, request)

    Logger.debug(fn ->
      "Committed offset #{topic}/#{partition}@#{offset} for #{group}"
    end)

    %State{
      state
      | committed_offset: offset,
        last_commit: :erlang.monotonic_time(:milli_seconds)
    }
  end

  defp load_offsets(
         %State{
           worker_name: worker_name,
           group: group,
           topic: topic,
           partition: partition
         } = state
       ) do
    request = %OffsetFetchRequest{
      consumer_group: group,
      topic: topic,
      partition: partition
    }

    [
      %OffsetFetchResponse{
        topic: ^topic,
        partitions: [
          %{partition: ^partition, error_code: error_code, offset: offset}
        ]
      }
    ] = KafkaEx.offset_fetch(worker_name, request)

    case error_code do
      :no_error ->
        %State{
          state
          | current_offset: offset,
            committed_offset: offset,
            acked_offset: offset
        }

      :unknown_topic_or_partition ->
        [
          %OffsetResponse{
            topic: ^topic,
            partition_offsets: [
              %{partition: ^partition, error_code: :no_error, offset: [offset]}
            ]
          }
        ] = KafkaEx.earliest_offset(topic, partition, worker_name)

        %State{
          state
          | current_offset: offset,
            committed_offset: offset,
            acked_offset: offset
        }
    end
  end
end
