defmodule ExampleSubscriber do
  use GenStage

  def start_link({pid, topic, partition, extra_consumer_args} = opts) do
    # GenServer.Options.t()
    {gen_server_options, _} = Keyword.split(extra_consumer_args, [:name, :debug])
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

  def do_work(event) do
    IO.inspect(event)
  end
end
