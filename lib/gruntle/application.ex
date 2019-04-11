defmodule Gruntle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

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
    consumer_group_name = "test"
    topic_names = ["fedora.hook"]

    children = [
      # ... other children
      supervisor(
        KafkaEx.ConsumerGroup,
        [
          {KafkaExGenStageConsumer, ExampleSubscriber},
          consumer_group_name,
          topic_names,
          consumer_group_opts
        ]
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
