class ProductCatalogPolicy < ApplicationPolicy
  def index?
    return true if @user.is_a?(AgentBot)

    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def show?
    return true if @user.is_a?(AgentBot)

    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end

  def bulk_upload?
    @account_user.administrator?
  end

  def bulk_delete?
    @account_user.administrator?
  end

  def export?
    @account_user.administrator?
  end

  def export_all?
    @account_user.administrator?
  end

  def download_export?
    @account_user.administrator?
  end

  def download_template?
    @account_user.administrator?
  end

  def toggle_visibility?
    @account_user.administrator?
  end
end
