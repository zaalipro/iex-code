defmodule IexCodeWeb.OwnerSessionHTML do
  use IexCodeWeb, :html

  def new(assigns) do
    assigns = Map.put(assigns, :form, to_form(%{}, as: :owner))

    ~H"""
    <main class="min-h-dvh flex items-center justify-center bg-canvas text-content px-6">
      <section class="w-full max-w-sm space-y-8">
        <header>
          <p class="text-xs uppercase tracking-widest text-muted">IexCode</p>
          <h1 class="mt-3 text-3xl font-semibold">Owner sign in</h1>
          <p class="mt-2 text-sm text-muted">Private access to your workspace.</p>
        </header>
        <p :if={@error} id="owner-login-error" role="alert" class="text-sm text-red-600">{@error}</p>
        <.form for={@form} id="owner-login-form" action={~p"/login"} method="post" class="space-y-5">
          <.input
            field={@form[:username]}
            id="owner-username"
            label="Username"
            autocomplete="username"
            required
            maxlength="64"
          />
          <.input
            field={@form[:password]}
            id="owner-password"
            type="password"
            label="Password"
            autocomplete="current-password"
            required
            maxlength="1024"
          />
          <button
            id="owner-login-submit"
            class="w-full rounded border border-edge px-4 py-3 text-sm font-medium transition-colors hover:bg-surface"
            type="submit"
          >Sign in</button>
        </.form>
      </section>
    </main>
    """
  end
end
