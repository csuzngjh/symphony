defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @label_lookup_query """
  query SymphonyResolveLabelId($teamId: String!, $labelName: String!) {
    team(id: $teamId) {
      labels(filter: {name: {eq: $labelName}}, first: 1) {
        nodes {
          id
        }
      }
    }
  }
  """

  @team_id_lookup_query """
  query SymphonyResolveTeamId($issueId: String!) {
    issue(id: $issueId) {
      team {
        id
      }
    }
  }
  """

  @add_labels_mutation """
  mutation SymphonyAddLabels($issueId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {labelIds: $labelIds}) {
      success
    }
  }
  """

  @issue_labels_query """
  query SymphonyIssueLabels($issueId: String!) {
    issue(id: $issueId) {
      labels {
        nodes {
          id
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name)
      when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, team_id} <- resolve_team_id(issue_id),
         {:ok, label_id} <- resolve_label_id(team_id, label_name),
         {:ok, existing_label_ids} <- fetch_existing_label_ids(issue_id) do
      if label_id in existing_label_ids do
        :ok
      else
        case client_module().graphql(@add_labels_mutation, %{issueId: issue_id, labelIds: [label_id | existing_label_ids]}) do
          {:ok, response} ->
            if get_in(response, ["data", "issueUpdate", "success"]) == true, do: :ok, else: {:error, :label_add_failed}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_team_id(issue_id) do
    with {:ok, response} <-
           client_module().graphql(@team_id_lookup_query, %{issueId: issue_id}),
         team_id when is_binary(team_id) <-
           get_in(response, ["data", "issue", "team", "id"]) do
      {:ok, team_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :team_not_found}
    end
  end

  defp resolve_label_id(team_id, label_name) do
    with {:ok, response} <-
           client_module().graphql(@label_lookup_query, %{teamId: team_id, labelName: label_name}),
         label_id when is_binary(label_id) <-
           get_in(response, ["data", "team", "labels", "nodes", Access.at(0), "id"]) do
      {:ok, label_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_not_found}
    end
  end

  defp fetch_existing_label_ids(issue_id) do
    case client_module().graphql(@issue_labels_query, %{issueId: issue_id}) do
      {:ok, response} ->
        label_ids =
          response
          |> get_in(["data", "issue", "labels", "nodes"])
          |> Kernel.||([])
          |> Enum.map(& &1["id"])
          |> Enum.reject(&is_nil/1)

        {:ok, label_ids}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
