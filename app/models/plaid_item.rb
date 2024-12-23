class PlaidItem < ApplicationRecord
  include Plaidable, Syncable

  encrypts :access_token, deterministic: true
  validates :name, :access_token, presence: true

  before_destroy :remove_plaid_item

  belongs_to :family
  has_one_attached :logo

  has_many :plaid_accounts, dependent: :destroy
  has_many :accounts, through: :plaid_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }

  class << self
    def create_from_public_token(token, item_name:)
      response = plaid_provider.exchange_public_token(token)

      new_plaid_item = create!(
        name: item_name,
        plaid_id: response.item_id,
        access_token: response.access_token,
      )

      new_plaid_item.sync_later
    end
  end

  def sync_data(start_date: nil)
    update!(last_synced_at: Time.current)

    fetch_and_load_plaid_data

    accounts.each do |account|
      account.sync_data(start_date: start_date)
    end
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def has_investment_accounts?
    available_products.include?("investments") || billed_products.include?("investments")
  end

  def has_liability_accounts?
    available_products.include?("liabilities") || billed_products.include?("liabilities")
  end

  private
    def fetch_and_load_plaid_data
      item = plaid_provider.get_item(access_token).item
      update!(available_products: item.available_products, billed_products: item.billed_products)

      fetched_accounts = plaid_provider.get_item_accounts(self).accounts

      internal_plaid_accounts = fetched_accounts.map do |account|
        internal_plaid_account = plaid_accounts.find_or_create_from_plaid_data!(account, family)
        internal_plaid_account.sync_account_data!(account)
        internal_plaid_account
      end

      fetched_transactions = safe_fetch_plaid_data(:get_item_transactions) unless has_investment_accounts?

      if fetched_transactions
        transaction do
          internal_plaid_accounts.each do |internal_plaid_account|
            added = fetched_transactions.added.select { |t| t.account_id == internal_plaid_account.plaid_id }
            modified = fetched_transactions.modified.select { |t| t.account_id == internal_plaid_account.plaid_id }
            removed = fetched_transactions.removed.select { |t| t.account_id == internal_plaid_account.plaid_id }

            internal_plaid_account.sync_transactions!(added:, modified:, removed:)
          end

          update!(next_cursor: fetched_transactions.cursor)
        end
      end

      fetched_investments = safe_fetch_plaid_data(:get_item_investments) if has_investment_accounts?

      if fetched_investments
        transaction do
          internal_plaid_accounts.each do |internal_plaid_account|
            transactions = fetched_investments.transactions.select { |t| t.account_id == internal_plaid_account.plaid_id }
            holdings = fetched_investments.holdings.select { |h| h.account_id == internal_plaid_account.plaid_id }
            securities = fetched_investments.securities

            internal_plaid_account.sync_investments!(transactions:, holdings:, securities:)
          end
        end
      end

      fetched_liabilities = safe_fetch_plaid_data(:get_item_liabilities) if has_liability_accounts?

      if fetched_liabilities
        transaction do
          internal_plaid_accounts.each do |internal_plaid_account|
            credit = fetched_liabilities.credit.find { |l| l.account_id == internal_plaid_account.plaid_id }
            mortgage = fetched_liabilities.mortgage.find { |l| l.account_id == internal_plaid_account.plaid_id }
            student = fetched_liabilities.student.find { |l| l.account_id == internal_plaid_account.plaid_id }

            internal_plaid_account.sync_credit_data!(credit) if credit
            internal_plaid_account.sync_mortgage_data!(mortgage) if mortgage
            internal_plaid_account.sync_student_loan_data!(student) if student
          end
        end
      end
    end

    def safe_fetch_plaid_data(method)
      begin
        plaid_provider.send(method, self)
      rescue Plaid::ApiError => e
        Rails.logger.warn("Error fetching #{method} for item #{id}: #{e.message}")
        nil
      end
    end

    def remove_plaid_item
      plaid_provider.remove_item(access_token)
    end
end
