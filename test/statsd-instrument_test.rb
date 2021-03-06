# Allow testing with the SystemTimer gem on 1.8
if RUBY_VERSION =~ /^1.8/
  puts "Loading SystemTimer gem"
  require 'system_timer'
end

require 'statsd-instrument'
require 'test/unit'
require 'mocha'
require 'logger'

StatsD.logger = Logger.new('/dev/null')

module ActiveMerchant; end
class ActiveMerchant::Base
  def ssl_post(arg)
    if arg
      'OK'
    else
      raise 'Not OK'
    end
  end
end

class ActiveMerchant::Gateway < ActiveMerchant::Base
  def purchase(arg)
    ssl_post(arg)
    true
  rescue
    false
  end

  def self.sync
    true
  end 

  def self.singleton_class
    class << self; self; end
  end
end

class ActiveMerchant::UniqueGateway < ActiveMerchant::Base
  def ssl_post(arg)
    {:success => arg}
  end

  def purchase(arg)
    ssl_post(arg)
  end
end

ActiveMerchant::Base.extend StatsD::Instrument

class StatsDTest < Test::Unit::TestCase
  def setup
    StatsD.mode = nil
    StatsD.stubs(:increment)
  end

  def test_statsd_count_if
    ActiveMerchant::Gateway.statsd_count_if :ssl_post, 'ActiveMerchant.Gateway.if'

    StatsD.expects(:increment).with(includes('if')).once
    ActiveMerchant::Gateway.new.purchase(true)
    ActiveMerchant::Gateway.new.purchase(false)
  end

  def test_statsd_count_if_with_block
    ActiveMerchant::UniqueGateway.statsd_count_if :ssl_post, 'ActiveMerchant.Gateway.block' do |result|
      result[:success]
    end

    StatsD.expects(:increment).with(includes('block')).once
    ActiveMerchant::UniqueGateway.new.purchase(true)
    ActiveMerchant::UniqueGateway.new.purchase(false)
  end

  def test_statsd_count_success
    ActiveMerchant::Gateway.statsd_count_success :ssl_post, 'ActiveMerchant.Gateway'

    StatsD.expects(:increment).with(includes('success'))
    ActiveMerchant::Gateway.new.purchase(true)

    StatsD.expects(:increment).with(includes('failure'))
    ActiveMerchant::Gateway.new.purchase(false)
  end

  def test_statsd_count_success_with_block
    ActiveMerchant::UniqueGateway.statsd_count_success :ssl_post, 'ActiveMerchant.Gateway' do |result|
      result[:success]
    end

    StatsD.expects(:increment).with(includes('success'))
    ActiveMerchant::UniqueGateway.new.purchase(true)

    StatsD.expects(:increment).with(includes('failure'))
    ActiveMerchant::UniqueGateway.new.purchase(false)
  end

  def test_statsd_count
    ActiveMerchant::Gateway.statsd_count :ssl_post, 'ActiveMerchant.Gateway.ssl_post'

    StatsD.expects(:increment).with(includes('ssl_post'))
    ActiveMerchant::Gateway.new.purchase(true)
  end

  def test_statsd_measure
    ActiveMerchant::UniqueGateway.statsd_measure :ssl_post, 'ActiveMerchant.Gateway.ssl_post'

    StatsD.expects(:write).with('ActiveMerchant.Gateway.ssl_post', is_a(Float), :ms).returns({:success => true})
    ActiveMerchant::UniqueGateway.new.purchase(true)
  end

  def test_instrumenting_class_method
    ActiveMerchant::Gateway.singleton_class.extend StatsD::Instrument
    ActiveMerchant::Gateway.singleton_class.statsd_count :sync, 'ActiveMerchant.Gateway.sync'

    StatsD.expects(:increment).with(includes('sync'))
    ActiveMerchant::Gateway.sync
  end

  def test_count_with_sampling
    StatsD.unstub(:increment)
    StatsD.stubs(:rand).returns(0.6)
    StatsD.logger.expects(:info).never

    StatsD.increment('sampling.foo.bar', 1, 0.1)
  end

  def test_count_with_successful_sample
    StatsD.unstub(:increment)
    StatsD.stubs(:rand).returns(0.01)
    StatsD.logger.expects(:info).once.with do |string|
      string.include?('@0.1')
    end

    StatsD.increment('sampling.foo.bar', 1, 0.1)
  end

  def test_production_mode_should_use_udp_socket
    StatsD.unstub(:increment)

    StatsD.mode = :production
    StatsD.server = 'localhost:123'
    UDPSocket.any_instance.expects(:send)

    StatsD.increment('fooz')
    StatsD.mode = :test
  end

  def test_write_supports_gauge_syntax
    StatsD.unstub(:gauge)

    StatsD.mode = :production
    StatsD.server = 'localhost:123'

    UDPSocket.any_instance.expects(:send).with('fooy:42|g', 0, 'localhost', 123)

    StatsD.gauge('fooy', 42)
  end

  def test_should_not_write_when_disabled
    StatsD.enabled = false
    StatsD.expects(:logger).never
    StatsD.increment('fooz')
    StatsD.enabled = true
  end

  def test_statsd_mode
    StatsD.unstub(:increment)
    StatsD.logger.expects(:info).once
    StatsD.expects(:socket_wrapper).twice
    StatsD.mode = :foo
    StatsD.increment('foo')
    StatsD.mode = :production
    StatsD.increment('foo')
    StatsD.mode = 'production'
    StatsD.increment('foo')
  end

  def test_statsd_prefix
    StatsD.unstub(:increment)
    StatsD.prefix = 'my_app'
    StatsD.logger.expects(:info).once.with do |string|
      string.include?('my_app.foo')
    end
    StatsD.logger.expects(:info).once.with do |string|
      string.include?('food')
    end
    StatsD.increment('foo')
    StatsD.prefix = nil
    StatsD.increment('food')
  end

  def test_statsd_measure_with_explicit_value
    StatsD.expects(:write).with('values.foobar', 42, :ms)

    StatsD.measure('values.foobar', 42)
  end

  def test_statsd_gauge
    StatsD.expects(:write).with('values.foobar', 12, :g, 1)

    StatsD.default_sample_rate = 1

    StatsD.gauge('values.foobar', 12)
  end

  def test_socket_error_should_not_raise
    StatsD.mode = :production
    UDPSocket.any_instance.expects(:send).raises(SocketError)
    StatsD.measure('values.foobar', 42)
    StatsD.mode = :test
  end

  def test_timeout_error_should_not_raise
    StatsD.mode = :production
    UDPSocket.any_instance.expects(:send).raises(Timeout::Error)
    StatsD.measure('values.foobar', 42)
    StatsD.mode = :test
  end

  def test_system_call_error_should_not_raise
    StatsD.mode = :production
    UDPSocket.any_instance.expects(:send).raises(Errno::ETIMEDOUT)
    StatsD.measure('values.foobar', 42)
    StatsD.mode = :test
  end

  def test_io_error_should_not_raise
    StatsD.mode = :production
    UDPSocket.any_instance.expects(:send).raises(IOError)
    StatsD.measure('values.foobar', 42)
    StatsD.mode = :test
  end

  def test_long_request_should_timeout
    StatsD.mode = :production
    UDPSocket.any_instance.expects(:send).yields do
      begin
        Timeout.timeout(0.5) { sleep 1 }
      rescue Timeout::Error
        raise "Allowed long running request"
      end
    end
    StatsD.measure('values.foobar', 42)
    StatsD.mode = :test
  end
end
