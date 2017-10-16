requires 'YAML::XS';
requires 'common::sense';
requires 'Net::BGP';
requires 'Net::BGP::Update';
requires 'List::Flatten';
requires 'Log::Any';
requires 'Log::Any::Adapter';


on test => sub {
    requires 'Devel::NYTProf';
    requires 'TAP::Formatter::JUnit';
    requires 'Test::More';
    requires 'Test::Exception';
    requires 'Devel::Cover';
    requires 'Devel::Cover::Report::Clover';
}