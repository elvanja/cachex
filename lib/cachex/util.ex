defmodule Cachex.Util do
  @moduledoc false
  # A small collection of utilities for use throughout the library. Mainly things
  # to do with response formatting and generally just common functions.

  @doc """
  Appends a string to an atom and returns as an atom.
  """
  def atom_append(atom, suffix),
  do: String.to_atom("#{atom}#{suffix}")

  @doc """
  Converts a number of memory bytes to a binary representation.
  """
  def bytes_to_readable(size),
  do: bytes_to_readable(size, ["B","KiB","MiB","GiB"])
  def bytes_to_readable(size, [_|tail]) when size >= 1024,
  do: bytes_to_readable(size / 1024, tail)
  def bytes_to_readable(size, [head|_]) do
    "~.2f ~s"
    |> :io_lib.format([size, head])
    |> IO.iodata_to_binary
  end

  @doc """
  Creates a match spec for the cache using the provided rules, and returning the
  provided return values. This is just shorthand for writing the same boilerplate
  spec over and over again.
  """
  def create_match(return, where) do
    normalized =
      return
      |> field_index
      |> List.wrap

    [ { { :"$1", :"$2", :"$3", :"$4" }, List.wrap(where), normalized } ]
  end

  @doc """
  Creates an input record based on a key, value and expiration. If the value
  passed is nil, then we apply any defaults. Otherwise we add the value
  to the current time (in milliseconds) and return a tuple for the table.
  """
  def create_record(%Cachex.State{ } = state, key, value, expiration \\ nil) do
    exp = case expiration do
      nil -> state.default_ttl
      val -> val
    end
    { key, now(), exp, value }
  end

  @doc """
  Takes an input and returns an ok/error tuple based on whether the input is of
  a truthy nature or not.
  """
  def create_truthy_result(result) do
    if result, do: ok(true), else: error(false)
  end

  @doc """
  Lazy wrapper for creating an :error tuple.
  """
  def error(value), do: { :error, value }

  @doc """
  Very small handler for appending "_janitor" to the name of a cache in order to
  create the name of a Janitor automatically.
  """
  def eternal_for_cache(cache) when is_atom(cache),
  do: atom_append(cache, "_eternal")

  @doc """
  Used to normalize some quick select syntax to valid Erlang handles. Used when
  creating match specifications instead of having `$` atoms everywhere.
  """
  def field_index(fields) when is_tuple(fields) do
    fields
    |> Tuple.to_list
    |> Enum.map(&field_index/1)
    |> List.to_tuple
    |> (&({ &1 })).()
  end
  def field_index(:key), do: :"$1"
  def field_index(:value), do: :"$4"
  def field_index(:touched), do: :"$2"
  def field_index(:ttl), do: :"$3"
  def field_index(field), do: field

  @doc """
  Retrieves a fallback value for a given key, using either the provided function
  or using the default fallback implementation.
  """
  def get_fallback(state, key, fb_fun \\ nil, default_val \\ nil) do
    fun = case get_fallback_function(state, fb_fun) do
      nil -> default_val
      val -> val
    end

    l =
      state.fallback_args
      |> length
      |> (&(&1 + 1)).()

    case fun do
      val when is_function(val) ->
        case :erlang.fun_info(val)[:arity] do
          0  ->
            { :loaded, val.() }
          1  ->
            { :loaded, val.(key) }
          ^l ->
            { :loaded, apply(val, [key|state.fallback_args]) }
          _  ->
            { :ok, default_val }
        end
      val ->
        { :ok, val }
    end
  end

  @doc """
  Finds a potential fallback function based on the provided state and a provided
  fallback function. The second arg takes priority, with the state defaults being
  used if none is provided.
  """
  def get_fallback_function(state, fb_fun \\ nil) do
    cond do
      is_function(fb_fun) ->
        fb_fun
      is_function(state.default_fallback) ->
        state.default_fallback
      true ->
        nil
    end
  end

  @doc """
  Pulls a boolean from a set of options. If the value is not a boolean, we return
  false unless a default value has been provided, in which case we return that.
  """
  def get_opt_boolean(options, key, default \\ false),
  do: get_opt(options, key, default, &is_boolean/1)

  @doc """
  Pulls a function from a set of options. If the value is not a function, we return
  nil unless a default value has been provided, in which case we return that.
  """
  def get_opt_function(options, key, default \\ nil),
  do: get_opt(options, key, default, &is_function/1)

  @doc """
  Pulls a list from a set of options. If the value is not a list, we return
  nil unless a default value has been provided, in which case we return that.
  """
  def get_opt_list(options, key, default \\ nil),
  do: get_opt(options, key, default, &is_list/1)

  @doc """
  Pulls a number from a set of options. If the value is not a number, we return
  nil unless a default value has been provided, in which case we return that.
  """
  def get_opt_number(options, key, default \\ nil),
  do: get_opt(options, key, default, &is_number/1)

  @doc """
  Pulls a positive number from a set of options. If the value is not positive, we
  return nil unless a default value has been provided, in which case we return that.
  """
  def get_opt_positive(options, key, default \\ nil),
  do: get_opt(options, key, default, &(is_number(&1) && &1 > 0))

  @doc """
  Pulls a value from a set of options. If the value satisfies the condition passed
  in, we return it. Otherwise we return a default value.
  """
  def get_opt(options, key, default, condition) do
    try do
      case options[key] do
        val -> if condition.(val), do: val, else: default
      end
    rescue
      _e -> default
    end
  end

  @doc """
  Small utility to figure out if a document has expired based on the last touched
  time and the TTL of the document.
  """
  def has_expired?(state, touched, ttl) when is_number(touched) and is_number(ttl) do
    if state.disable_ode, do: false, else: touched + ttl < now
  end
  def has_expired?(_state, _touched, _ttl), do: false
  def has_expired?(touched, ttl) when is_number(touched) and is_number(ttl) do
    touched + ttl < now
  end
  def has_expired?(_touched, _ttl), do: false

  @doc """
  Shorthand increments for a map key. If the value is not a number, it is assumed
  to be 0.
  """
  def increment_map_key(map, key, amount) do
    { _, updated_map } = Map.get_and_update(map, key, fn
      (val) when is_number(val) ->
        { val, amount + val }
      (val) ->
        { val, amount }
    end)
    updated_map
  end

  @doc """
  Very small handler for appending "_janitor" to the name of a cache in order to
  create the name of a Janitor automatically.
  """
  def janitor_for_cache(cache) when is_atom(cache),
  do: atom_append(cache, "_janitor")

  @doc """
  Retrieves the last item in a Tuple. This is just shorthand around sizeof and
  pulling the last element.
  """
  def last_of_tuple(tuple) when is_tuple(tuple) do
    case tuple_size(tuple) do
      0 -> nil
      n -> elem(tuple, n - 1)
    end
  end

  @doc """
  Very small handler for appending "_lock_manager" to the name of a cache in order
  to create the name of a LockManager automatically.
  """
  def manager_for_cache(cache),
  do: atom_append(cache, "_lock_manager")

  @doc """
  Lazy wrapper for creating a :noreply tuple.
  """
  def noreply(state), do: { :noreply, state }
  def noreply(_value, state), do: { :noreply, state }

  @doc """
  Very small unwrapper for an Mnesia start result. We accept already started tables
  due to re-creation inside tests and setup/teardown scenarios.
  """
  def normalize_started({ :ok, _pid }),
    do: { :ok, true }
  def normalize_started({ :error, { :already_started, _pid } }),
    do: { :ok, true }
  def normalize_started(err),
    do: err

  @doc """
  Consistency wrapper around current time in millis.
  """
  def now, do: :os.system_time(1000)

  @doc """
  Lazy wrapper for creating an :ok tuple.
  """
  def ok(value), do: { :ok, value }

  @doc """
  Lazy wrapper for creating a :reply tuple.
  """
  def reply(value, state), do: { :reply, value, state }

  @doc """
  Returns a selection to return the designated value for all rows. Enables things
  like finding all stored keys and all stored values.
  """
  def retrieve_all_rows(return) do
    create_match(return, [
      {
        :orelse,                                # guards for matching
        { :"==", :"$3", nil },                  # where a TTL is not set
        { :">", { :"+", :"$2", :"$3" }, now }   # or the TTL has not passed
      }
    ])
  end

  @doc """
  Returns a selection to return the designated value for all expired rows.
  """
  def retrieve_expired_rows(return) do
    create_match(return, [
      {
        :andalso,                               # guards for matching
        { :"/=", :"$3", nil },                  # where a TTL is set
        { :"<", { :"+", :"$2", :"$3" }, now }   # and the TTL has passed
      }
    ])
  end

  @doc """
  Very small handler for appending "_stats" to the name of a cache in order to
  create the name of a stats hook automatically.
  """
  def stats_for_cache(cache) when is_atom(cache),
  do: atom_append(cache, "_stats")

  @doc """
  Determines if a value is truthy or not. This just adds a little bit of extra
  readability where needed.
  """
  def truthy?(value), do: !!value

end
