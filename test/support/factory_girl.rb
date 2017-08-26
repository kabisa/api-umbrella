# Include serializable_hash customizations so that the data generated in tests
# also matches the app behavior of using "id" fields instead of "_id".
require File.join(API_UMBRELLA_SRC_ROOT, "src/api-umbrella/web-app/config/initializers/mongoid_serializable_id.rb")
FactoryGirl.find_definitions

module FactoryGirl
  # Either return the results of FactoryGirl.attributes_for or
  # FactirlGirl.build for a given factory, depending on what the current
  # factory strategy is.
  #
  # The use case for this is to be called for nested association factory data,
  # so that when attributes_for is being used, the factory returns nested
  # hashes of data, but if create or build is being used, the factory returns
  # ActiveRecord objects (which ActiveRecord can then handle saving).
  #
  # This isn't the most standard way to handle embedded associations inside
  # FactoryGirl, but it lets us leverage the same factories for both
  # building/creating records, as well as returning hashes of data in the
  # format expected of our APIs (for POST/PUT calls).
  def self.attributes_or_build(current_strategy, name, *traits_and_overrides, &block)
    if(current_strategy.kind_of?(FactoryGirl::Strategy::AttributesFor))
      self.attributes_for(name, *traits_and_overrides, &block)
    else
      self.build(name, *traits_and_overrides, &block)
    end
  end
end