defmodule Explorer.Chain.Import.Runner.InternalTransactions do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.InternalTransactions.t/0`.
  """

  require Ecto.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.{Block, Hash, Import, InternalTransaction, PendingBlockOperation, Transaction}
  alias Explorer.Chain.Import.Runner
  alias Explorer.Repo, as: ExplorerRepo

  import Ecto.Query, only: [from: 2, or_where: 3]

  @behaviour Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [InternalTransaction.t()]

  @impl Runner
  def ecto_schema_module, do: InternalTransaction

  @impl Runner
  def option_key, do: :internal_transactions

  @impl Runner
  def imported_table_row do
    %{
      value_type: "[%{index: non_neg_integer(), transaction_hash: Explorer.Chain.Hash.t()}]",
      value_description: "List of maps of the `t:Explorer.Chain.InternalTransaction.t/0` `index` and `transaction_hash`"
    }
  end

  @impl Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) when is_map(options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    transactions_timeout = options[Runner.Transactions.option_key()][:timeout] || Runner.Transactions.timeout()

    update_transactions_options = %{timeout: transactions_timeout, timestamps: timestamps}

    # filter out params with just `block_number` (indicating blocks without internal transactions)
    internal_transactions_params = Enum.filter(changes_list, &Map.has_key?(&1, :type))

    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    multi
    |> Multi.run(:acquire_blocks, fn repo, _ ->
      acquire_blocks(repo, changes_list)
    end)
    |> Multi.run(:acquire_pending_internal_txs, fn repo, %{acquire_blocks: block_hashes} ->
      acquire_pending_internal_txs(repo, block_hashes)
    end)
    |> Multi.run(:acquire_transactions, fn repo, %{acquire_pending_internal_txs: pending_block_hashes} ->
      acquire_transactions(repo, pending_block_hashes)
    end)
    |> Multi.run(:invalid_block_numbers, fn _, %{acquire_transactions: transactions} ->
      invalid_block_numbers(transactions, internal_transactions_params)
    end)
    |> Multi.run(:valid_internal_transactions_without_first_traces_of_trivial_transactions, fn _,
                                                                                               %{
                                                                                                 acquire_transactions:
                                                                                                   transactions,
                                                                                                 invalid_block_numbers:
                                                                                                   invalid_block_numbers
                                                                                               } ->
      valid_internal_transactions_without_first_trace(
        transactions,
        internal_transactions_params,
        invalid_block_numbers
      )
    end)
    |> Multi.run(:valid_internal_transactions, fn _,
                                                  %{
                                                    acquire_transactions: transactions,
                                                    invalid_block_numbers: invalid_block_numbers
                                                  } ->
      valid_internal_transactions(
        transactions,
        internal_transactions_params,
        invalid_block_numbers
      )
    end)
    |> Multi.run(:remove_left_over_internal_transactions, fn repo,
                                                             %{valid_internal_transactions: valid_internal_transactions} ->
      remove_left_over_internal_transactions(repo, valid_internal_transactions)
    end)
    |> Multi.run(:internal_transactions, fn repo,
                                            %{
                                              valid_internal_transactions_without_first_traces_of_trivial_transactions:
                                                valid_internal_transactions_without_first_traces_of_trivial_transactions
                                            } ->
      insert(repo, valid_internal_transactions_without_first_traces_of_trivial_transactions, insert_options)
    end)
    |> Multi.run(:update_transactions, fn repo, %{valid_internal_transactions: valid_internal_transactions} ->
      update_transactions(repo, valid_internal_transactions, update_transactions_options)
    end)
    |> Multi.run(:remove_consensus_of_invalid_blocks, fn repo, %{invalid_block_numbers: invalid_block_numbers} ->
      remove_consensus_of_invalid_blocks(repo, invalid_block_numbers)
    end)
    |> Multi.run(:update_pending_blocks_status, fn repo,
                                                   %{
                                                     acquire_pending_internal_txs: pending_block_hashes,
                                                     remove_consensus_of_invalid_blocks: invalid_block_hashes
                                                   } ->
      update_pending_blocks_status(repo, pending_block_hashes, invalid_block_hashes)
    end)
  end

  def run_insert_only(changes_list, %{timestamps: timestamps} = options) when is_map(options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    # filter out params with just `block_number` (indicating blocks without internal transactions)
    internal_transactions_params = Enum.filter(changes_list, &Map.has_key?(&1, :type))

    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    Multi.new()
    |> Multi.run(:internal_transactions, fn repo, _ ->
      insert(repo, internal_transactions_params, insert_options)
    end)
    |> ExplorerRepo.transaction()
  end

  @impl Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map], %{
          optional(:on_conflict) => Runner.on_conflict(),
          required(:timeout) => timeout,
          required(:timestamps) => Import.timestamps()
        }) ::
          {:ok, [%{index: non_neg_integer, transaction_hash: Hash.t()}]}
          | {:error, [Changeset.t()]}
  defp insert(repo, valid_internal_transactions, %{timeout: timeout, timestamps: timestamps} = options)
       when is_list(valid_internal_transactions) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    ordered_changes_list = Enum.sort_by(valid_internal_transactions, &{&1.transaction_hash, &1.index})

    {:ok, internal_transactions} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        conflict_target: [:block_hash, :block_index],
        for: InternalTransaction,
        on_conflict: on_conflict,
        returning: true,
        timeout: timeout,
        timestamps: timestamps
      )

    {:ok, internal_transactions}
  end

  defp default_on_conflict do
    from(
      internal_transaction in InternalTransaction,
      update: [
        set: [
          block_number: fragment("EXCLUDED.block_number"),
          call_type: fragment("EXCLUDED.call_type"),
          created_contract_address_hash: fragment("EXCLUDED.created_contract_address_hash"),
          created_contract_code: fragment("EXCLUDED.created_contract_code"),
          error: fragment("EXCLUDED.error"),
          from_address_hash: fragment("EXCLUDED.from_address_hash"),
          gas: fragment("EXCLUDED.gas"),
          gas_used: fragment("EXCLUDED.gas_used"),
          index: fragment("EXCLUDED.index"),
          init: fragment("EXCLUDED.init"),
          input: fragment("EXCLUDED.input"),
          output: fragment("EXCLUDED.output"),
          to_address_hash: fragment("EXCLUDED.to_address_hash"),
          trace_address: fragment("EXCLUDED.trace_address"),
          transaction_hash: fragment("EXCLUDED.transaction_hash"),
          transaction_index: fragment("EXCLUDED.transaction_index"),
          type: fragment("EXCLUDED.type"),
          value: fragment("EXCLUDED.value"),
          inserted_at: fragment("LEAST(?, EXCLUDED.inserted_at)", internal_transaction.inserted_at),
          updated_at: fragment("GREATEST(?, EXCLUDED.updated_at)", internal_transaction.updated_at)
          # Don't update `block_hash` as it is used for the conflict target
          # Don't update `block_index` as it is used for the conflict target
        ]
      ],
      # `IS DISTINCT FROM` is used because it allows `NULL` to be equal to itself
      where:
        fragment(
          "(EXCLUDED.transaction_hash, EXCLUDED.index, EXCLUDED.call_type, EXCLUDED.created_contract_address_hash, EXCLUDED.created_contract_code, EXCLUDED.error, EXCLUDED.from_address_hash, EXCLUDED.gas, EXCLUDED.gas_used, EXCLUDED.init, EXCLUDED.input, EXCLUDED.output, EXCLUDED.to_address_hash, EXCLUDED.trace_address, EXCLUDED.transaction_index, EXCLUDED.type, EXCLUDED.value) IS DISTINCT FROM (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          internal_transaction.transaction_hash,
          internal_transaction.index,
          internal_transaction.call_type,
          internal_transaction.created_contract_address_hash,
          internal_transaction.created_contract_code,
          internal_transaction.error,
          internal_transaction.from_address_hash,
          internal_transaction.gas,
          internal_transaction.gas_used,
          internal_transaction.init,
          internal_transaction.input,
          internal_transaction.output,
          internal_transaction.to_address_hash,
          internal_transaction.trace_address,
          internal_transaction.transaction_index,
          internal_transaction.type,
          internal_transaction.value
        )
    )
  end

  defp acquire_blocks(repo, changes_list) do
    block_numbers = Enum.map(changes_list, & &1.block_number)

    query =
      from(
        b in Block,
        where: b.number in ^block_numbers and b.consensus,
        select: b.hash,
        # Enforce Block ShareLocks order (see docs: sharelocks.md)
        order_by: [asc: b.hash],
        lock: "FOR UPDATE"
      )

    {:ok, repo.all(query)}
  end

  defp acquire_pending_internal_txs(repo, block_hashes) do
    query =
      from(
        pending_ops in PendingBlockOperation,
        where: pending_ops.block_hash in ^block_hashes,
        where: pending_ops.fetch_internal_transactions,
        select: pending_ops.block_hash,
        # Enforce PendingBlockOperation ShareLocks order (see docs: sharelocks.md)
        order_by: [asc: pending_ops.block_hash],
        lock: "FOR UPDATE"
      )

    {:ok, repo.all(query)}
  end

  defp acquire_transactions(repo, pending_block_hashes) do
    query =
      from(
        t in Transaction,
        where: t.block_hash in ^pending_block_hashes,
        select: map(t, [:hash, :block_hash, :block_number]),
        # Enforce Transaction ShareLocks order (see docs: sharelocks.md)
        order_by: t.hash,
        lock: "FOR UPDATE"
      )

    {:ok, repo.all(query)}
  end

  defp invalid_block_numbers(transactions, internal_transactions_params) do
    # Finds all mistmatches between transactions and internal transactions
    # for a block number:
    # - there are no internal txs for some transactions
    # - there are no transactions for some internal transactions
    # - there are internal txs with a different block number than their transactions
    # Returns block numbers where any of these issues is found

    required_tuples = MapSet.new(transactions, &{&1.hash, &1.block_number})

    candidate_tuples = MapSet.new(internal_transactions_params, &{&1.transaction_hash, &1.block_number})

    all_tuples = MapSet.union(required_tuples, candidate_tuples)

    common_tuples = MapSet.intersection(required_tuples, candidate_tuples)

    invalid_numbers =
      all_tuples
      |> MapSet.difference(common_tuples)
      |> MapSet.new(fn {_hash, block_number} -> block_number end)
      |> MapSet.to_list()

    {:ok, invalid_numbers}
  end

  defp valid_internal_transactions(transactions, internal_transactions_params, invalid_block_numbers) do
    blocks_map = Map.new(transactions, &{&1.block_number, &1.block_hash})

    valid_internal_txs =
      internal_transactions_params
      |> Enum.group_by(& &1.block_number)
      |> Map.drop(invalid_block_numbers)
      |> Enum.flat_map(fn {block_number, entries} ->
        block_hash = Map.fetch!(blocks_map, block_number)

        entries
        |> Enum.sort_by(&{&1.transaction_hash, &1.index})
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} ->
          entry
          |> Map.put(:block_hash, block_hash)
          |> Map.put(:block_index, index)
        end)
      end)

    {:ok, valid_internal_txs}
  end

  defp valid_internal_transactions_without_first_trace(
         transactions,
         internal_transactions_params,
         invalid_block_numbers
       ) do
    with {:ok, valid_internal_txs} <-
           valid_internal_transactions(transactions, internal_transactions_params, invalid_block_numbers) do
      json_rpc_named_arguments = Application.fetch_env!(:indexer, :json_rpc_named_arguments)
      variant = Keyword.fetch!(json_rpc_named_arguments, :variant)

      # we exclude first traces from storing in the DB only in case of Parity variant (Parity/Nethermind). todo: to the same for Geth
      if variant == EthereumJSONRPC.Parity do
        valid_internal_txs_without_first_trace =
          valid_internal_txs
          |> Enum.reject(fn trace ->
            trace[:index] == 0
          end)

        {:ok, valid_internal_txs_without_first_trace}
      else
        {:ok, valid_internal_txs}
      end
    end
  end

  def defer_internal_transactions_primary_key(repo) do
    # Allows internal_transactions primary key to not be checked during the
    # DB transactions and instead be checked only at the end of it.
    # This allows us to use a more efficient upserting logic, while keeping the
    # uniqueness valid.
    SQL.query(repo, "SET CONSTRAINTS internal_transactions_pkey DEFERRED")
  end

  def remove_left_over_internal_transactions(repo, valid_internal_transactions) do
    # Removes internal transactions that were part of a block before a refetch
    # and have not been upserted with new ones (if any exist).

    case valid_internal_transactions do
      [] ->
        {:ok, []}

      _ ->
        try do
          delete_query_for_block_hash_block_index =
            valid_internal_transactions
            |> Enum.group_by(& &1.block_hash, & &1.block_index)
            |> Enum.map(fn {block_hash, indexes} -> {block_hash, Enum.max(indexes)} end)
            |> Enum.reduce(InternalTransaction, fn {block_hash, max_index}, acc ->
              or_where(acc, [it], it.block_hash == ^block_hash and it.block_index > ^max_index)
            end)

          # removes old records with the same primary key (transaction hash, transaction index)
          delete_query =
            valid_internal_transactions
            |> Enum.map(fn params -> {params.transaction_hash, params.index} end)
            |> Enum.reduce(delete_query_for_block_hash_block_index, fn {transaction_hash, index}, acc ->
              or_where(acc, [it], it.transaction_hash == ^transaction_hash and it.index == ^index)
            end)

          # ShareLocks order already enforced by `acquire_pending_internal_txs` (see docs: sharelocks.md)
          {count, result} = repo.delete_all(delete_query, [])

          {:ok, {count, result}}
        rescue
          postgrex_error in Postgrex.Error -> {:error, %{exception: postgrex_error}}
        end
    end
  end

  defp update_transactions(repo, valid_internal_transactions, %{
         timeout: timeout,
         timestamps: timestamps
       }) do
    valid_internal_transactions_count = Enum.count(valid_internal_transactions)

    if valid_internal_transactions_count == 0 do
      {:ok, nil}
    else
      params =
        valid_internal_transactions
        |> Enum.filter(fn internal_tx ->
          internal_tx[:index] == 0
        end)
        |> Enum.map(fn trace ->
          %{
            transaction_hash: Map.get(trace, :transaction_hash),
            created_contract_address_hash: Map.get(trace, :created_contract_address_hash),
            error: Map.get(trace, :error),
            status: if(is_nil(Map.get(trace, :error)), do: :ok, else: :error)
          }
        end)
        |> Enum.filter(fn transaction_hash -> transaction_hash != nil end)

      transaction_hashes =
        valid_internal_transactions
        |> MapSet.new(& &1.transaction_hash)
        |> MapSet.to_list()

      result =
        Enum.reduce_while(params, 0, fn first_trace, transaction_hashes_iterator ->
          update_query =
            from(
              t in Transaction,
              where: t.hash == ^first_trace.transaction_hash,
              # ShareLocks order already enforced by `acquire_transactions` (see docs: sharelocks.md)
              update: [
                set: [
                  created_contract_address_hash: ^first_trace.created_contract_address_hash,
                  error: ^first_trace.error,
                  status: ^first_trace.status,
                  updated_at: ^timestamps.updated_at
                ]
              ]
            )

          transaction_hashes_iterator = transaction_hashes_iterator + 1

          try do
            {_transaction_count, result} = repo.update_all(update_query, [], timeout: timeout)

            if valid_internal_transactions_count == transaction_hashes_iterator do
              {:halt, result}
            else
              {:cont, transaction_hashes_iterator}
            end
          rescue
            postgrex_error in Postgrex.Error ->
              {:halt, %{exception: postgrex_error, transaction_hashes: transaction_hashes}}
          end
        end)

      case result do
        %{exception: _} ->
          {:error, result}

        _ ->
          {:ok, result}
      end
    end
  end

  defp remove_consensus_of_invalid_blocks(repo, invalid_block_numbers) do
    update_query =
      from(
        b in Block,
        where: b.number in ^invalid_block_numbers and b.consensus,
        select: b.hash,
        # ShareLocks order already enforced by `acquire_blocks` (see docs: sharelocks.md)
        update: [set: [consensus: false]]
      )

    try do
      {_num, result} = repo.update_all(update_query, [])

      Logger.debug(fn ->
        [
          "consensus removed from blocks with numbers: ",
          inspect(invalid_block_numbers),
          " because of mismatching transactions"
        ]
      end)

      {:ok, result}
    rescue
      postgrex_error in Postgrex.Error ->
        {:error, %{exception: postgrex_error, invalid_block_numbers: invalid_block_numbers}}
    end
  end

  def update_pending_blocks_status(repo, pending_hashes, invalid_block_hashes) do
    valid_block_hashes =
      pending_hashes
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(invalid_block_hashes))
      |> MapSet.to_list()

    delete_query =
      from(
        pending_ops in PendingBlockOperation,
        where: pending_ops.block_hash in ^valid_block_hashes
      )

    try do
      # ShreLocks order already enforced by `acquire_pending_internal_txs` (see docs: sharelocks.md)
      {_count, deleted} = repo.delete_all(delete_query, [])

      {:ok, deleted}
    rescue
      postgrex_error in Postgrex.Error ->
        {:error, %{exception: postgrex_error, pending_hashes: valid_block_hashes}}
    end
  end
end