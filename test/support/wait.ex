defmodule Smolsqls.Wait do
  @moduledoc """
  Polling helper for asserting on state that settles asynchronously — a
  WAL feed applying an event, a background refresh landing, in-flight
  work draining.

  Only for genuinely asynchronous convergence. Do not use it to order
  steps within a test: a poll loop standing in for a handshake passes
  locally, flakes in CI, and stops exercising the case it was written for
  as soon as timings shift. Where the code under test can signal (a
  message, an injected function, a synchronous call), handshake on that
  instead.

  Several test files still carry their own private `wait_until/2`; new
  tests should use this one.
  """

  @doc """
  Polls `fun` until it returns a truthy value, then returns `:ok`. On the
  last attempt the result is asserted, so a timeout fails the test at the
  condition rather than on a mystery timeout.
  """
  @spec until((-> as_boolean(term())), pos_integer(), pos_integer()) :: :ok
  def until(fun, attempts \\ 400, interval_ms \\ 25)

  def until(fun, 0, _interval_ms) do
    if fun.(),
      do: :ok,
      else: ExUnit.Assertions.flunk("Wait.until/3 gave up waiting for the condition")
  end

  def until(fun, attempts, interval_ms) do
    if fun.() do
      :ok
    else
      Process.sleep(interval_ms)
      until(fun, attempts - 1, interval_ms)
    end
  end
end
