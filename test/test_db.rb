require 'helper'
require 'rcs-collector/db.rb'
require 'singleton'

module RCS
module Collector

# dirty hack to fake the trace function
# re-open the class and override the method
class DB
  def trace(a, b)
    #puts b
  end
end

# mockup for the config singleton
class Config
  include Singleton
  def initialize
    @global = {'DB_ADDRESS' => 'test',
               'DB_PORT' => '0',
               'DB_SIGN' => 'rcs-client.sig',
               'DB_CERT' => 'rcs-client.pem'}
  end
end

# fake xmlrpc class used during the DB initialize
class DB_xmlrpc
  def trace(a, b)
  end
end

# this class is a mockup for the db layer
# it will implement fake response to test the DB class
class DB_mockup
  def initialize
    @@failure = false
  end

  # used the change the behavior of the mockup methods
  def self.failure=(value)
    @@failure = value
  end

  # mockup methods
  def login(user, pass); return (@@failure) ? false : true; end
  def logout; end
  def backdoor_signature
    raise if @@failure
    return "signature"
  end
  def class_keys
    raise if @@failure
    return {'BUILD001' => 'secret class key', 'BUILD002' => "another secret"}
  end
  def status_of(build_id, instance_id, subtype)
    raise if @@failure
    # return status, bid
    return DB::ACTIVE_BACKDOOR, 1
  end
  def new_conf(bid)
    raise if @@failure
    # return cid, config
    return 1, "this is the binary config"
  end
  def new_uploads(bid)
    raise if @@failure
    return { 1 => {:filename => 'filename1', :content => "file content 1"},
             2 => {:filename => 'filename2', :content => "file content 2"}}
  end
  def new_downloads(bid)
    raise if @@failure
    return { 1 => 'pattern'}
  end
  def new_filesystems(bid)
    raise if @@failure
    return { 1 => {:depth => 1, :path => 'pattern'}}
  end
end

class TestDB < Test::Unit::TestCase

  def setup
    # take the internal variable representing the db layer to be used
    # and mock it for the tests
    DB.instance.instance_variable_set(:@db, DB_mockup.new)
    # clear the cache
    Cache.destroy!
    # every test begins with the db connected
    DB_mockup.failure = false
    DB.instance.connect!
    assert_true DB.instance.connected?
  end

  def teardown
    Cache.destroy!
  end

  def test_connect
    DB_mockup.failure = true
    DB.instance.connect!
    assert_false DB.instance.connected?
  end

  def test_disconnect
    DB.instance.disconnect!
    assert_false DB.instance.connected?
  end

  def test_private_method
    # a private method, nobody should call it
    assert_raise NoMethodError do
      DB.instance.connected = false
    end
  end

  def test_cache_init
    assert_true DB.instance.cache_init
    assert_equal Digest::MD5.digest('signature'), DB.instance.backdoor_signature
    assert_equal Digest::MD5.digest('secret class key'), DB.instance.class_key_of('BUILD001')

    DB_mockup.failure = true
    # this will fail to reach the db 
    assert_false DB.instance.cache_init
    assert_false DB.instance.connected?
    assert_equal Digest::MD5.digest('signature'), DB.instance.backdoor_signature
    assert_equal Digest::MD5.digest('secret class key'), DB.instance.class_key_of('BUILD001')

    # now the error was reported to the DB layer, so it should init correctly
    assert_true DB.instance.cache_init
    assert_equal Digest::MD5.digest('signature'), DB.instance.backdoor_signature
    assert_equal Digest::MD5.digest('secret class key'), DB.instance.class_key_of('BUILD001')
  end

  def test_class_key
    # this is taken from the mockup
    assert_equal Digest::MD5.digest('secret class key'), DB.instance.class_key_of('BUILD001')
    # not existing build from mockup
    assert_equal nil, DB.instance.class_key_of('404')

    DB_mockup.failure = true
    # we have it in the cache
    assert_equal Digest::MD5.digest('secret class key'), DB.instance.class_key_of('BUILD001')
    assert_false DB.instance.connected?
    # not existing build in the cache and the db is failing
    assert_equal nil, DB.instance.class_key_of('404')
  end

  def test_status_of
    assert_equal [DB::ACTIVE_BACKDOOR, 1], DB.instance.status_of('BUILD001', 'inst', 'type')
    # during the db failure, we must be able to continue
    DB_mockup.failure = true
    assert_equal [DB::UNKNOWN_BACKDOOR, 0], DB.instance.status_of('BUILD001', 'inst', 'type')
    assert_false DB.instance.connected?
    # now the layer is aware of the failure
    assert_equal [DB::UNKNOWN_BACKDOOR, 0], DB.instance.status_of('BUILD001', 'inst', 'type')
  end

  def test_new_conf
    assert_true DB.instance.new_conf?(1)
    assert_equal "this is the binary config", DB.instance.new_conf(1)

    DB_mockup.failure = true
    assert_false DB.instance.new_conf?(1)
    assert_false DB.instance.connected?
    assert_equal nil, DB.instance.new_conf(1)
  end

  def test_new_uploads
    assert_true DB.instance.new_uploads?(1)
    upl, left = DB.instance.new_uploads(1)
    # we have two fake uploads
    assert_equal 1, left
    assert_equal "filename1", upl[:filename]
    assert_equal "file content 1", upl[:content]
    # get the second one
    upl, left = DB.instance.new_uploads(1)
    assert_equal 0, left
    assert_equal "filename2", upl[:filename]
    assert_equal "file content 2", upl[:content]

    DB_mockup.failure = true
    assert_false DB.instance.new_uploads?(1)
    assert_false DB.instance.connected?
    upl, left = DB.instance.new_uploads(1)
    assert_equal nil, upl
  end

  def test_new_downloads
    assert_true DB.instance.new_downloads?(1)
    assert_equal ["pattern"], DB.instance.new_downloads(1)

    DB_mockup.failure = true
    assert_false DB.instance.new_downloads?(1)
    assert_false DB.instance.connected?
    assert_equal [], DB.instance.new_downloads(1)
  end

  def test_new_filesystems
    assert_true DB.instance.new_filesystems?(1)
    assert_equal [{:depth => 1, :path => "pattern"}], DB.instance.new_filesystems(1)

    DB_mockup.failure = true
    assert_false DB.instance.new_filesystems?(1)
    assert_false DB.instance.connected?
    assert_equal [], DB.instance.new_filesystems(1)
  end

end
    
end #Collector::
end #RCS::
